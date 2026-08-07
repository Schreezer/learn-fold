#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define OUTPUT_LIMIT_BYTES (48U * 1024U)
#define ADDRESS_SPACE_LIMIT_BYTES (256U * 1024U * 1024U)
#define FILE_SIZE_LIMIT_BYTES (64U * 1024U * 1024U)
#define PROCESS_LIMIT 32U
#define OPEN_FILE_LIMIT 128U
#define WORKSPACE_GROWTH_LIMIT_BYTES (64ULL * 1024ULL * 1024ULL)
#define WORKSPACE_TOTAL_LIMIT_BYTES (512ULL * 1024ULL * 1024ULL)
#define WORKSPACE_ENTRY_LIMIT 100000ULL
#define WORKSPACE_DEPTH_LIMIT 64U
#define SETUP_ERROR_PREFIX "learnfold-course-exec: "

static int status_fd = -1;

static int64_t monotonic_milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return -1;
    }
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int parse_positive_id(const char *value, unsigned long *result) {
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed == 0) {
        return -1;
    }
    *result = parsed;
    return 0;
}

static int setup_error(const char *operation) {
    if (status_fd >= 0) {
        dprintf(status_fd, "setup\t%s\n", operation);
    }
    fprintf(stderr, SETUP_ERROR_PREFIX "%s: %s\n", operation, strerror(errno));
    return 125;
}

static void write_script_status(int was_truncated, int workspace_limit_exceeded) {
    if (status_fd >= 0) {
        dprintf(
            status_fd,
            "script\ttruncated=%d\tworkspace_limit=%d\n",
            was_truncated,
            workspace_limit_exceeded
        );
    }
}

static int set_limit(int resource, rlim_t value) {
    const struct rlimit limit = { .rlim_cur = value, .rlim_max = value };
    return setrlimit(resource, &limit);
}

struct workspace_usage {
    uint64_t bytes;
    uint64_t entries;
};

static int add_workspace_bytes(struct workspace_usage *usage, off_t size) {
    uint64_t positive_size = size > 0 ? (uint64_t)size : 0;
    if (UINT64_MAX - usage->bytes < positive_size) {
        errno = EOVERFLOW;
        return -1;
    }
    usage->bytes += positive_size;
    return 0;
}

static int scan_workspace_directory(
    int directory_fd,
    unsigned int depth,
    struct workspace_usage *usage
) {
    if (depth > WORKSPACE_DEPTH_LIMIT) {
        close(directory_fd);
        errno = ELOOP;
        return -1;
    }

    DIR *directory = fdopendir(directory_fd);
    if (directory == NULL) {
        close(directory_fd);
        return -1;
    }

    int result = 0;
    errno = 0;
    for (;;) {
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                result = -1;
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }

        struct stat metadata;
        if (fstatat(
                dirfd(directory),
                entry->d_name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) != 0) {
            // Concurrent scripts can legitimately remove or replace an entry
            // between readdir and fstatat. Any other failure is treated as a
            // quota violation so permissions cannot hide disk usage.
            if (errno == ENOENT || errno == ENOTDIR) {
                errno = 0;
                continue;
            }
            result = -1;
            break;
        }

        usage->entries += 1;
        if (usage->entries > WORKSPACE_ENTRY_LIMIT
            || add_workspace_bytes(usage, metadata.st_size) != 0) {
            errno = EFBIG;
            result = -1;
            break;
        }

        if (S_ISDIR(metadata.st_mode)) {
            int child_fd = openat(
                dirfd(directory),
                entry->d_name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            );
            if (child_fd < 0) {
                if (errno == ENOENT || errno == ENOTDIR || errno == ELOOP) {
                    errno = 0;
                    continue;
                }
                result = -1;
                break;
            }
            if (scan_workspace_directory(child_fd, depth + 1, usage) != 0) {
                result = -1;
                break;
            }
        }
        errno = 0;
    }

    int saved_errno = errno;
    if (closedir(directory) != 0 && result == 0) {
        return -1;
    }
    errno = saved_errno;
    return result;
}

static int read_workspace_usage(struct workspace_usage *usage) {
    usage->bytes = 0;
    usage->entries = 0;
    int root_fd = open(
        "/workspace",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    );
    if (root_fd < 0) {
        return -1;
    }
    return scan_workspace_directory(root_fd, 0, usage);
}

static int apply_resource_limits(unsigned long timeout_seconds) {
    if (set_limit(RLIMIT_CORE, 0) != 0
        || set_limit(RLIMIT_FSIZE, FILE_SIZE_LIMIT_BYTES) != 0
        || set_limit(RLIMIT_NOFILE, OPEN_FILE_LIMIT) != 0
        || set_limit(RLIMIT_NPROC, PROCESS_LIMIT) != 0
        || set_limit(RLIMIT_AS, ADDRESS_SPACE_LIMIT_BYTES) != 0
        || set_limit(RLIMIT_CPU, (rlim_t)timeout_seconds + 2) != 0) {
        return -1;
    }
    return 0;
}

static void kill_job(pid_t pid) {
    // Linux excludes the caller from kill(-1). Because this controller has
    // already irreversibly dropped to the course uid, this reaches every
    // course process (including descendants that created a new session) but
    // cannot signal root-owned iSH or app processes.
    (void)kill(-1, SIGKILL);
    (void)kill(-pid, SIGKILL);
    (void)kill(pid, SIGKILL);
}

static void forward_bounded_output(
    int fd,
    size_t *forwarded,
    int *was_truncated,
    int *reached_eof
) {
    char buffer[8192];
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count > 0) {
            size_t available = *forwarded < OUTPUT_LIMIT_BYTES
                ? OUTPUT_LIMIT_BYTES - *forwarded
                : 0;
            size_t to_write = (size_t)count < available ? (size_t)count : available;
            size_t offset = 0;
            while (offset < to_write) {
                ssize_t written = write(STDOUT_FILENO, buffer + offset, to_write - offset);
                if (written > 0) {
                    offset += (size_t)written;
                } else if (written < 0 && errno == EINTR) {
                    continue;
                } else {
                    break;
                }
            }
            *forwarded += to_write;
            if (to_write < (size_t)count) {
                *was_truncated = 1;
            }
            continue;
        }
        if (count == 0) {
            *reached_eof = 1;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        return;
    }
}

static int child_exit_code(int status) {
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 6) {
        fputs(SETUP_ERROR_PREFIX "usage: UID GID TIMEOUT_SECONDS STATUS_FD SCRIPT\n", stderr);
        return 125;
    }

    unsigned long uid_value = 0;
    unsigned long gid_value = 0;
    unsigned long timeout_value = 0;
    unsigned long status_fd_value = 0;
    if (parse_positive_id(argv[1], &uid_value) != 0
        || parse_positive_id(argv[2], &gid_value) != 0
        || parse_positive_id(argv[3], &timeout_value) != 0
        || parse_positive_id(argv[4], &status_fd_value) != 0
        || status_fd_value > INT32_MAX) {
        fputs(SETUP_ERROR_PREFIX "invalid identity or timeout\n", stderr);
        return 125;
    }
    status_fd = (int)status_fd_value;

    if (apply_resource_limits(timeout_value) != 0) {
        return setup_error("setrlimit");
    }

    int output_pipe[2];
    if (pipe2(output_pipe, O_CLOEXEC) != 0) {
        return setup_error("pipe2");
    }
    int exec_error_pipe[2];
    if (pipe2(exec_error_pipe, O_CLOEXEC | O_NONBLOCK) != 0) {
        return setup_error("exec status pipe");
    }

    if (setgroups(0, NULL) != 0
        || setresgid((gid_t)gid_value, (gid_t)gid_value, (gid_t)gid_value) != 0
        || setresuid((uid_t)uid_value, (uid_t)uid_value, (uid_t)uid_value) != 0
        || chdir("/workspace") != 0
        || clearenv() != 0
        || setenv("PATH", "/bin", 1) != 0
        || setenv("HOME", "/workspace", 1) != 0
        || setenv("USER", "learnfold", 1) != 0
        || setenv("LOGNAME", "learnfold", 1) != 0
        || setenv("PWD", "/workspace", 1) != 0
        || setenv("TMPDIR", "/tmp", 1) != 0
        || setenv("LANG", "C", 1) != 0
        || setenv("LC_ALL", "C", 1) != 0) {
        return setup_error("sandbox setup");
    }

    struct workspace_usage initial_usage;
    if (read_workspace_usage(&initial_usage) != 0) {
        return setup_error("workspace usage");
    }
    const int recovery_only = initial_usage.bytes > WORKSPACE_TOTAL_LIMIT_BYTES
        || initial_usage.entries > WORKSPACE_ENTRY_LIMIT;

    pid_t child = fork();
    if (child < 0) {
        return setup_error("fork");
    }
    if (child == 0) {
        close(output_pipe[0]);
        close(exec_error_pipe[0]);
        close(status_fd);
        if (dup2(output_pipe[1], STDOUT_FILENO) < 0
            || dup2(output_pipe[1], STDERR_FILENO) < 0) {
            (void)write(exec_error_pipe[1], "dup2", 4);
            _exit(125);
        }
        close(output_pipe[1]);
        if (setsid() < 0) {
            (void)write(exec_error_pipe[1], "setsid", 6);
            fputs(SETUP_ERROR_PREFIX "setsid failed\n", stderr);
            _exit(125);
        }
        (void)prctl(PR_SET_PDEATHSIG, SIGKILL);
        execl("/bin/sh", "sh", "-c", argv[5], (char *)NULL);
        (void)write(exec_error_pipe[1], "exec", 4);
        fprintf(stderr, SETUP_ERROR_PREFIX "exec: %s\n", strerror(errno));
        _exit(125);
    }

    close(output_pipe[1]);
    close(exec_error_pipe[1]);
    int flags = fcntl(output_pipe[0], F_GETFL, 0);
    if (flags < 0 || fcntl(output_pipe[0], F_SETFL, flags | O_NONBLOCK) != 0) {
        kill_job(child);
        return setup_error("fcntl");
    }

    // The controller must not itself pin the live workspace mount.
    if (chdir("/") != 0) {
        kill_job(child);
        return setup_error("leave workspace");
    }

    int64_t started = monotonic_milliseconds();
    int status = 0;
    int child_finished = 0;
    int reached_eof = 0;
    int was_truncated = 0;
    int timed_out = 0;
    int workspace_limit_exceeded = 0;
    size_t forwarded = 0;

    while (!child_finished) {
        forward_bounded_output(
            output_pipe[0],
            &forwarded,
            &was_truncated,
            &reached_eof
        );
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) {
            child_finished = 1;
            break;
        }
        if (waited < 0 && errno != EINTR) {
            kill_job(child);
            close(output_pipe[0]);
            return setup_error("waitpid");
        }

        int64_t now = monotonic_milliseconds();
        if (started < 0 || now < 0
            || now - started >= (int64_t)timeout_value * 1000) {
            timed_out = 1;
            kill_job(child);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            child_finished = 1;
            break;
        }

        struct workspace_usage current_usage;
        int usage_result = read_workspace_usage(&current_usage);
        uint64_t growth = current_usage.bytes > initial_usage.bytes
            ? current_usage.bytes - initial_usage.bytes
            : 0;
        const int exceeds_recovery_baseline = recovery_only
            && (current_usage.bytes > initial_usage.bytes
                || current_usage.entries > initial_usage.entries);
        const int exceeds_normal_limits = !recovery_only
            && (growth > WORKSPACE_GROWTH_LIMIT_BYTES
                || current_usage.bytes > WORKSPACE_TOTAL_LIMIT_BYTES
                || current_usage.entries > WORKSPACE_ENTRY_LIMIT);
        if (usage_result != 0
            || exceeds_recovery_baseline
            || exceeds_normal_limits) {
            workspace_limit_exceeded = 1;
            kill_job(child);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            child_finished = 1;
            break;
        }

        struct pollfd descriptor = {
            .fd = output_pipe[0],
            .events = POLLIN | POLLHUP,
            .revents = 0,
        };
        (void)poll(&descriptor, 1, 20);
    }

    // A non-interactive shell may leave background descendants alive. Kill
    // every process owned by the isolated course uid, then drain only the
    // bounded tail already present in the pipe.
    kill_job(child);
    for (int attempts = 0; attempts < 10 && !reached_eof; attempts++) {
        forward_bounded_output(
            output_pipe[0],
            &forwarded,
            &was_truncated,
            &reached_eof
        );
        if (!reached_eof) {
            struct pollfd descriptor = {
                .fd = output_pipe[0],
                .events = POLLIN | POLLHUP,
                .revents = 0,
            };
            (void)poll(&descriptor, 1, 10);
        }
    }
    close(output_pipe[0]);

    char exec_error[16];
    ssize_t exec_error_count = read(exec_error_pipe[0], exec_error, sizeof(exec_error));
    close(exec_error_pipe[0]);
    if (exec_error_count > 0) {
        if (status_fd >= 0) {
            dprintf(status_fd, "setup\tchild-%.*s\n", (int)exec_error_count, exec_error);
        }
        return 125;
    }
    write_script_status(was_truncated, workspace_limit_exceeded);
    if (workspace_limit_exceeded) {
        fputs("\n[workspace growth limit exceeded]\n", stdout);
        return 122;
    }
    return timed_out ? 124 : child_exit_code(status);
}
