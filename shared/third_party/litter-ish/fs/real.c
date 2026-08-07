#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <sys/mman.h>
#include <sys/xattr.h>
#include <sys/file.h>
#include <poll.h>

#include "debug.h"
#include "kernel/errno.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "fs/dev.h"
#include "fs/devices.h"
#include "fs/real.h"
#define ISH_INTERNAL
#include "fs/fake.h"
#include "fs/tty.h"
#include "platform/platform.h"
#include "util/fchdir.h"

int realfs_getpath(struct fd *fd, char *buf);

static bool realfs_is_readonly(const struct mount *mount) {
    return mount != NULL && (mount->flags & MS_READONLY_) != 0;
}

static int open_flags_real_from_fake(int flags) {
    int real_flags = 0;
    if (flags & O_RDONLY_) real_flags |= O_RDONLY;
    if (flags & O_WRONLY_) real_flags |= O_WRONLY;
    if (flags & O_RDWR_) real_flags |= O_RDWR;
    if (flags & O_CREAT_) real_flags |= O_CREAT;
    if (flags & O_EXCL_) real_flags |= O_EXCL;
    if (flags & O_TRUNC_) real_flags |= O_TRUNC;
    if (flags & O_APPEND_) real_flags |= O_APPEND;
    if (flags & O_NONBLOCK_) real_flags |= O_NONBLOCK;
    return real_flags;
}

static int open_flags_fake_from_real(int flags) {
    int fake_flags = 0;
    if (flags & O_RDONLY) fake_flags |= O_RDONLY_;
    if (flags & O_WRONLY) fake_flags |= O_WRONLY_;
    if (flags & O_RDWR) fake_flags |= O_RDWR_;
    if (flags & O_CREAT) fake_flags |= O_CREAT_;
    if (flags & O_EXCL) fake_flags |= O_EXCL_;
    if (flags & O_TRUNC) fake_flags |= O_TRUNC_;
    if (flags & O_APPEND) fake_flags |= O_APPEND_;
    if (flags & O_NONBLOCK) fake_flags |= O_NONBLOCK_;
    return fake_flags;
}

// Resolve every host path component beneath the mount using directory file
// descriptors. Guest path normalization alone is insufficient: another guest
// process can otherwise replace an already-checked host component with a
// symlink before openat(2), escaping the mounted directory.
static int realfs_parent_fd(struct mount *mount, const char *path, char *leaf) {
    const char *fixed = fix_path(path);
    size_t length = strlen(fixed);
    if (length >= MAX_PATH) {
        errno = ENAMETOOLONG;
        return -1;
    }

    char copy[MAX_PATH];
    memcpy(copy, fixed, length + 1);
    int current_fd = dup(mount->root_fd);
    if (current_fd < 0)
        return -1;

    char *cursor = copy;
    while (*cursor == '/') cursor++;
    if (*cursor == '\0' || strcmp(cursor, ".") == 0) {
        strcpy(leaf, ".");
        return current_fd;
    }

    for (;;) {
        char *separator = strchr(cursor, '/');
        if (separator == NULL) {
            size_t leaf_length = strlen(cursor);
            if (leaf_length == 0 || leaf_length > NAME_MAX
                    || strcmp(cursor, ".") == 0 || strcmp(cursor, "..") == 0) {
                close(current_fd);
                errno = EINVAL;
                return -1;
            }
            memcpy(leaf, cursor, leaf_length + 1);
            return current_fd;
        }

        *separator = '\0';
        if (*cursor == '\0' || strcmp(cursor, ".") == 0 || strcmp(cursor, "..") == 0) {
            close(current_fd);
            errno = EINVAL;
            return -1;
        }
        int next_fd = openat(
            current_fd,
            cursor,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        );
        int saved_errno = errno;
        close(current_fd);
        if (next_fd < 0) {
            errno = saved_errno;
            return -1;
        }
        current_fd = next_fd;
        cursor = separator + 1;
        while (*cursor == '/') cursor++;
    }
}

static int realfs_open_beneath(
    struct mount *mount,
    const char *path,
    int flags,
    mode_t mode
) {
    char leaf[NAME_MAX + 1];
    int parent_fd = realfs_parent_fd(mount, path, leaf);
    if (parent_fd < 0)
        return -1;
    int fd = openat(parent_fd, leaf, flags | O_NOFOLLOW | O_CLOEXEC, mode);
    int saved_errno = errno;
    close(parent_fd);
    errno = saved_errno;
    return fd;
}

// Map well-known /dev paths to device numbers. Returns 0 if not recognized.
static dev_t_ realfs_devnum_for_path(const char *path) {
    if (strncmp(path, "/dev/", 5) != 0)
        return 0;
    const char *devname = path + 5;
    if (strcmp(devname, "null") == 0)
        return dev_make(MEM_MAJOR, DEV_NULL_MINOR);
    if (strcmp(devname, "zero") == 0)
        return dev_make(MEM_MAJOR, DEV_ZERO_MINOR);
    if (strcmp(devname, "full") == 0)
        return dev_make(MEM_MAJOR, DEV_FULL_MINOR);
    if (strcmp(devname, "random") == 0)
        return dev_make(MEM_MAJOR, DEV_RANDOM_MINOR);
    if (strcmp(devname, "urandom") == 0)
        return dev_make(MEM_MAJOR, DEV_URANDOM_MINOR);
    if (strcmp(devname, "tty") == 0)
        return dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR);
    if (strcmp(devname, "console") == 0)
        return dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR);
    if (strcmp(devname, "ptmx") == 0)
        return dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR);
    return 0;
}

struct fd *realfs_open(struct mount *mount, const char *path, int flags, int mode) {
    if (realfs_is_readonly(mount)
        && (flags & (O_WRONLY_ | O_RDWR_ | O_CREAT_ | O_TRUNC_ | O_APPEND_))) {
        return ERR_PTR(_EROFS);
    }
    int real_flags = open_flags_real_from_fake(flags);
    int fd_no = realfs_open_beneath(mount, path, real_flags, mode);
    if (fd_no < 0)
        return ERR_PTR(errno_map());
    struct fd *fd = fd_create(&realfs_fdops);
    fd->real_fd = fd_no;
    fd->dir = NULL;
    return fd;
}

int realfs_close(struct fd *fd) {
    if (fd->dir != NULL)
        closedir(fd->dir);
    int err = close(fd->real_fd);
    if (err < 0)
        return errno_map();
    return 0;
}

static void copy_stat(struct statbuf *fake_stat, struct stat *real_stat) {
    fake_stat->dev = dev_fake_from_real(real_stat->st_dev);
    fake_stat->inode = real_stat->st_ino;
    fake_stat->mode = real_stat->st_mode;
    fake_stat->nlink = real_stat->st_nlink;
    fake_stat->uid = real_stat->st_uid;
    fake_stat->gid = real_stat->st_gid;
    fake_stat->rdev = dev_fake_from_real(real_stat->st_rdev);
    fake_stat->size = real_stat->st_size;
    fake_stat->blksize = real_stat->st_blksize;
    fake_stat->blocks = real_stat->st_blocks;
    fake_stat->atime = platform_stat_atime_sec(real_stat);
    fake_stat->mtime = platform_stat_mtime_sec(real_stat);
    fake_stat->ctime = platform_stat_ctime_sec(real_stat);
    fake_stat->atime_nsec = platform_stat_atime_nsec(real_stat);
    fake_stat->mtime_nsec = platform_stat_mtime_nsec(real_stat);
    fake_stat->ctime_nsec = platform_stat_ctime_nsec(real_stat);
}

int realfs_stat(struct mount *mount, const char *path, struct statbuf *fake_stat) {
    struct stat real_stat;
    char leaf[NAME_MAX + 1];
    int parent_fd = realfs_parent_fd(mount, path, leaf);
    if (parent_fd < 0)
        return errno_map();
    int result = fstatat(parent_fd, leaf, &real_stat, AT_SYMLINK_NOFOLLOW);
    int saved_errno = errno;
    close(parent_fd);
    errno = saved_errno;
    if (result < 0)
        return errno_map();
    copy_stat(fake_stat, &real_stat);
    // Override mode/rdev for well-known device paths backed by placeholder files
    dev_t_ devnum = realfs_devnum_for_path(path);
    if (devnum != 0) {
        fake_stat->mode = S_IFCHR | 0666;
        fake_stat->rdev = devnum;
    }
    return 0;
}

int realfs_fstat(struct fd *fd, struct statbuf *fake_stat) {
    struct stat real_stat;
    if (fstat(fd->real_fd, &real_stat) < 0)
        return errno_map();
    copy_stat(fake_stat, &real_stat);

    // For fakefs/rootfs images we often ship placeholder regular files under
    // /dev rather than real device nodes. Preserve the Linux-visible device
    // semantics by reclassifying well-known device paths on fstat(), just like
    // realfs_stat() already does for path-based lookup.
    char path[MAX_PATH];
    if (fd->mount != NULL && realfs_getpath(fd, path) == 0) {
        dev_t_ devnum = realfs_devnum_for_path(path);
        if (devnum != 0) {
            fake_stat->mode = S_IFCHR | 0666;
            fake_stat->rdev = devnum;
        }
    }
    return 0;
}

static bool realfs_should_surface_eintr(void) {
    if (current->group->doing_group_exit)
        return true;
    if (current->sighand != NULL) {
        lock(&current->sighand->lock);
        bool pending = !!(current->pending & ~current->blocked);
        unlock(&current->sighand->lock);
        if (pending)
            return true;
    }
    return false;
}

ssize_t realfs_read(struct fd *fd, void *buf, size_t bufsize) {
    ssize_t res;
    do {
        res = read(fd->real_fd, buf, bufsize);
    } while (res < 0 && errno == EINTR && !realfs_should_surface_eintr());
    if (res < 0)
        return errno_map();
    return res;
}

ssize_t realfs_write(struct fd *fd, const void *buf, size_t bufsize) {
    if (realfs_is_readonly(fd->mount))
        return _EROFS;
    ssize_t res;
    do {
        res = write(fd->real_fd, buf, bufsize);
    } while (res < 0 && errno == EINTR && !realfs_should_surface_eintr());
    if (res < 0)
        return errno_map();
    return res;
}

ssize_t realfs_pread(struct fd *fd, void *buf, size_t bufsize, off_t off) {
    ssize_t res;
    do {
        res = pread(fd->real_fd, buf, bufsize, off);
    } while (res < 0 && errno == EINTR);
    if (res < 0)
        return errno_map();
    return res;
}

ssize_t realfs_pwrite(struct fd *fd, const void *buf, size_t bufsize, off_t off) {
    if (realfs_is_readonly(fd->mount))
        return _EROFS;
    ssize_t res;
    do {
        res = pwrite(fd->real_fd, buf, bufsize, off);
    } while (res < 0 && errno == EINTR);
    if (res < 0)
        return errno_map();
    return res;
}

void realfs_opendir(struct fd *fd) {
    if (fd->dir == NULL) {
        int dirfd = dup(fd->real_fd);
        if (dirfd < 0) return;
        fd->dir = fdopendir(dirfd);
        if (fd->dir == NULL) {
            // fdopendir failed (fd may not be a directory, or was closed).
            // Close the dup'd fd and leave fd->dir NULL for callers to handle.
            close(dirfd);
        }
    }
}

int realfs_readdir(struct fd *fd, struct dir_entry *entry) {
    realfs_opendir(fd);
    if (fd->dir == NULL) return _EIO;
    // Darwin filenames (APFS/HFS+) can be up to 255 UTF-16 units, which in
    // UTF-8 may exceed Linux NAME_MAX (255 bytes). An unchecked strcpy into
    // entry->name[NAME_MAX + 1] smashes the caller's stack-allocated
    // dir_entry (see sys_getdents64 in fs/dir.c) and trips __stack_chk_fail.
    // Skip any entry whose name doesn't fit so the guest can continue walking.
    for (;;) {
        errno = 0;
        struct dirent *dirent = readdir(fd->dir);
        if (dirent == NULL) {
            if (errno != 0)
                return errno_map();
            return 0;
        }
        size_t namelen = strlen(dirent->d_name);
        if (namelen > NAME_MAX) {
            FIXME("realfs_readdir: skipping entry with name longer than NAME_MAX (%zu bytes)", namelen);
            continue;
        }
        entry->inode = dirent->d_ino;
        entry->type = dirent->d_type;
        memcpy(entry->name, dirent->d_name, namelen + 1);
        return 1;
    }
}

unsigned long realfs_telldir(struct fd *fd) {
    realfs_opendir(fd);
    if (fd->dir == NULL) return 0;
    return telldir(fd->dir);
}

void realfs_seekdir(struct fd *fd, unsigned long ptr) {
    realfs_opendir(fd);
    if (fd->dir == NULL) return;
    seekdir(fd->dir, ptr);
}

off_t realfs_lseek(struct fd *fd, off_t offset, int whence) {
    if (fd->dir != NULL && whence == LSEEK_SET) {
        realfs_seekdir(fd, offset);
        return offset;
    }

    if (whence == LSEEK_SET)
        whence = SEEK_SET;
    else if (whence == LSEEK_CUR)
        whence = SEEK_CUR;
    else if (whence == LSEEK_END)
        whence = SEEK_END;
    else
        return _EINVAL;
    off_t res = lseek(fd->real_fd, offset, whence);
    if (res < 0)
        return errno_map();
    return res;
}

int realfs_poll(struct fd *fd) {
    struct pollfd p = {.fd = fd->real_fd, .events = POLLPRI};
    // prevent POLLNVAL
    int flags = fcntl(fd->real_fd, F_GETFL, 0);
    if ((flags & O_ACCMODE) != O_WRONLY)
        p.events |= POLLIN;
    if ((flags & O_ACCMODE) != O_RDONLY)
        p.events |= POLLOUT;
    if (poll(&p, 1, 0) <= 0)
        return 0;

#if defined(__APPLE__)
    // this is the "WTF is apple smoking" section

    // https://github.com/apple/darwin-xnu/blob/a449c6a3b8014d9406c2ddbdc81795da24aa7443/bsd/kern/sys_generic.c#L1856
    if (p.revents & POLLHUP)
        p.revents |= POLLOUT;
    // apparently you can sometimes get POLLPRI on a pipe??? please ignore how much of a mess this condition is
    if (is_adhoc_fd(fd) && S_ISFIFO(fd->stat.mode))
        p.revents &= ~POLLPRI;

    if (p.revents & POLLNVAL) {
        printk("pollnval %d flags %d events %d revents %d\n", fd->real_fd, flags, p.events, p.revents);
        // Darwin poll can report POLLNVAL for broad event masks without
        // telling us which individual readiness bits are still meaningful.
        // Ask for each event class separately and ignore POLLNVAL noise.
        // This is no longer atomic, but it preserves useful readiness bits.
        int events = 0;
        static const int pollbits[] = {POLLIN, POLLOUT, POLLPRI};
        for (unsigned i = 0; i < sizeof(pollbits)/sizeof(pollbits[0]); i++) {
            p.events = pollbits[i];
            if (poll(&p, 1, 0) > 0 && !(p.revents & POLLNVAL))
                events |= p.revents;
        }
        assert(!(events & POLLNVAL));
        return events;
    }
#endif

    assert(!(p.revents & POLLNVAL));
    return p.revents;
}

int realfs_mmap(struct fd *fd, struct mem *mem, page_t start, pages_t pages, off_t offset, int prot, int flags) {
    if (realfs_is_readonly(fd->mount) && (prot & P_WRITE) && (flags & MMAP_SHARED))
        return _EROFS;
    int mmap_flags = 0;
    if (flags & MMAP_PRIVATE) mmap_flags |= MAP_PRIVATE;
    if (flags & MMAP_SHARED) mmap_flags |= MAP_SHARED;
    int mmap_prot = PROT_READ;
    if (prot & P_WRITE) mmap_prot |= PROT_WRITE;

    off_t real_offset = (offset / real_page_size) * real_page_size;
    off_t correction = offset - real_offset;
    size_t map_size = (pages * PAGE_SIZE) + correction;

    struct stat st;
    int have_stat = (fstat(fd->real_fd, &st) == 0);

    // Check if the mapping extends beyond the file size.
    if (have_stat && (off_t)(real_offset + map_size) > st.st_size) {
        // For MAP_SHARED writable mappings, use a direct file-backed mmap.
        // The host kernel handles beyond-EOF correctly: writes within the
        // file are flushed on munmap, and the zero-filled region between
        // file end and page boundary is discarded. This is what apk needs
        // for its posix_fallocate + mmap(MAP_SHARED) extraction pattern.
        // We must NOT extend the file via ftruncate, because apk doesn't
        // truncate it back, leaving trailing null bytes that corrupt files.
        if ((mmap_flags & MAP_SHARED) && (mmap_prot & PROT_WRITE)) {
            char *memory = mmap(NULL, map_size,
                    mmap_prot, mmap_flags, fd->real_fd, real_offset);
            if (memory != MAP_FAILED) {
                return pt_map(mem, start, pages, memory, correction, prot);
            }
            // mmap failed — fall through to anonymous path
        }

        // Create anonymous backing for the full range (zeros for BSS)
        char *memory = mmap(NULL, map_size,
                PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (memory == MAP_FAILED)
            return _ENOMEM;
        size_t file_bytes = 0;
        if (st.st_size > real_offset)
            file_bytes = st.st_size - real_offset;
        if (file_bytes > map_size)
            file_bytes = map_size;
        size_t file_map_size = (file_bytes / real_page_size) * real_page_size;
        if (file_map_size > 0) {
            char *file_map = mmap(memory, file_map_size,
                    mmap_prot, mmap_flags | MAP_FIXED, fd->real_fd, real_offset);
            if (file_map == MAP_FAILED)
                file_map_size = 0;
        }
        if (file_map_size < file_bytes) {
            size_t remaining = file_bytes - file_map_size;
            size_t total_read = 0;
            while (total_read < remaining) {
                ssize_t n = pread(fd->real_fd, memory + file_map_size + total_read,
                                  remaining - total_read,
                                  real_offset + file_map_size + total_read);
                if (n <= 0) break;
                total_read += n;
            }
        }
        if (!(mmap_prot & PROT_WRITE) && file_map_size < map_size)
            mprotect(memory + file_map_size, map_size - file_map_size, mmap_prot);

        return pt_map(mem, start, pages, memory, correction, prot);
    }

    char *memory = mmap(NULL, map_size,
            mmap_prot, mmap_flags, fd->real_fd, real_offset);
    if (memory == MAP_FAILED)
        return _ENOMEM;

    return pt_map(mem, start, pages, memory, correction, prot);
}

ssize_t realfs_readlink(struct mount *mount, const char *path, char *buf, size_t bufsize) {
    char leaf[NAME_MAX + 1];
    int parent_fd = realfs_parent_fd(mount, path, leaf);
    if (parent_fd < 0)
        return errno_map();
    ssize_t size = readlinkat(parent_fd, leaf, buf, bufsize);
    int saved_errno = errno;
    close(parent_fd);
    errno = saved_errno;
    if (size < 0)
        return errno_map();
    return size;
}

int realfs_getpath(struct fd *fd, char *buf) {
    int err = platform_fd_get_path(fd->real_fd, buf, MAX_PATH);
    if (err < 0)
        return err;

    /* For bind-mounted dirs, F_GETPATH resolves symlinks and returns the
     * host persistent path (e.g. /Users/.../MinisChat/minis/<sid>/attachments).
     * This won't start with mount->source, so the normal prefix strip fails.
     * Detect and translate back to the Linux path. */
    char linux_path[MAX_PATH];
    if (fakefs_bind_mount_resolve_path(buf, linux_path, sizeof(linux_path))) {
        if (strstr(buf, "minis") != NULL)
            fprintf(stderr, "realfs_getpath: bind_mount_resolve OK: \"%s\" -> \"%s\"\n", buf, linux_path);
        strlcpy(buf, linux_path, MAX_PATH);
        return 0;
    }
    if (strstr(buf, "minis") != NULL)
        fprintf(stderr, "realfs_getpath: bind_mount_resolve MISS: F_GETPATH=\"%s\" source=\"%s\"\n", buf, fd->mount->source);

    if (strcmp(fd->mount->source, "/") != 0 || strcmp(buf, "/") == 0) {
        size_t source_len = strlen(fd->mount->source);
        /* Verify buf actually starts with mount->source before stripping.
         * F_GETPATH resolves symlinks, so bind-mounted paths may point outside
         * mount->source when the bind mount table has been cleared (e.g. after
         * app restart before mountMinis re-registers the mounts). */
        if (strncmp(buf, fd->mount->source, source_len) == 0) {
            memmove(buf, buf + source_len, MAX_PATH - source_len);
        } else if (strncmp(fd->mount->source, "/var/", 5) == 0 &&
                   strncmp(buf, "/private", 8) == 0 &&
                   strncmp(buf + 8, fd->mount->source, source_len) == 0) {
            /* F_GETPATH returns /private/var/... but mount->source is /var/...
             * Strip /private prefix + mount->source from buf. */
            memmove(buf, buf + 8 + source_len, MAX_PATH - 8 - source_len);
        } else {
            /* Path is outside mount source (stale bind mount symlink resolved
             * by F_GETPATH). Return root as a safe fallback. */
            strcpy(buf, "/");
        }
    }
    return 0;
}

int realfs_link(struct mount *mount, const char *src, const char *dst) {
    if (realfs_is_readonly(mount))
        return _EROFS;
    char src_leaf[NAME_MAX + 1];
    char dst_leaf[NAME_MAX + 1];
    int src_parent = realfs_parent_fd(mount, src, src_leaf);
    if (src_parent < 0)
        return errno_map();
    int dst_parent = realfs_parent_fd(mount, dst, dst_leaf);
    if (dst_parent < 0) {
        int saved_errno = errno;
        close(src_parent);
        errno = saved_errno;
        return errno_map();
    }
    int res = linkat(src_parent, src_leaf, dst_parent, dst_leaf, 0);
    int saved_errno = errno;
    close(src_parent);
    close(dst_parent);
    errno = saved_errno;
    if (res < 0)
        return errno_map();
    return res;
}

int realfs_unlink(struct mount *mount, const char *path) {
    if (realfs_is_readonly(mount))
        return _EROFS;
    char leaf[NAME_MAX + 1];
    int parent_fd = realfs_parent_fd(mount, path, leaf);
    if (parent_fd < 0)
        return errno_map();
    int res = unlinkat(parent_fd, leaf, 0);
    int saved_errno = errno;
    close(parent_fd);
    errno = saved_errno;
    if (res < 0)
        return errno_map();
    return res;
}

int realfs_rmdir(struct mount *mount, const char *path) {
    if (realfs_is_readonly(mount))
        return _EROFS;
    char leaf[NAME_MAX + 1];
    int parent_fd = realfs_parent_fd(mount, path, leaf);
    if (parent_fd < 0)
        return errno_map();
    int err = unlinkat(parent_fd, leaf, AT_REMOVEDIR);
    int saved_errno = errno;
    close(parent_fd);
    errno = saved_errno;
    if (err < 0)
        return errno_map();
    return 0;
}

int realfs_rename(struct mount *mount, const char *src, const char *dst) {
    if (realfs_is_readonly(mount))
        return _EROFS;
    char src_leaf[NAME_MAX + 1];
    char dst_leaf[NAME_MAX + 1];
    int src_parent = realfs_parent_fd(mount, src, src_leaf);
    if (src_parent < 0)
        return errno_map();
    int dst_parent = realfs_parent_fd(mount, dst, dst_leaf);
    if (dst_parent < 0) {
        int saved_errno = errno;
        close(src_parent);
        errno = saved_errno;
        return errno_map();
    }
    int err = renameat(src_parent, src_leaf, dst_parent, dst_leaf);
    int saved_errno = errno;
    close(src_parent);
    close(dst_parent);
    errno = saved_errno;
    if (err < 0)
        return errno_map();
    return err;
}

int realfs_symlink(struct mount *mount, const char *target, const char *link) {
    // Host symlinks outlive the confined shell. Later native app code (SQLite,
    // FileManager, CloudKit reconciliation) may follow them with broader host
    // authority, turning the shell into a confused deputy. Course workspaces
    // support ordinary files, directories, and hard links, but not symlinks.
    (void)mount;
    (void)target;
    (void)link;
    return _EPERM;
}

int realfs_mknod(struct mount *mount, const char *path, mode_t_ mode, dev_t_ UNUSED(dev)) {
    if (realfs_is_readonly(mount))
        return _EROFS;
    char leaf[NAME_MAX + 1];
    int parent_fd = realfs_parent_fd(mount, path, leaf);
    if (parent_fd < 0)
        return errno_map();
    int err;
    if (S_ISREG(mode)) {
        err = openat(
            parent_fd,
            leaf,
            O_CREAT | O_EXCL | O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
            mode & ~S_IFMT
        );
        if (err >= 0)
            err = close(err);
    } else {
        // Persistent FIFOs and Unix socket nodes can block later native reads
        // or survive the shell's process lifetime. Course mounts support only
        // ordinary files and directories.
        close(parent_fd);
        return _EPERM;
    }
    int saved_errno = errno;
    close(parent_fd);
    errno = saved_errno;
    if (err < 0)
        return errno_map();
    return err;
}

int realfs_truncate(struct mount *mount, const char *path, off_t_ size) {
    if (realfs_is_readonly(mount))
        return _EROFS;
    int fd = realfs_open_beneath(mount, path, O_RDWR, 0);
    if (fd < 0)
        return errno_map();
    int err = 0;
    if (ftruncate(fd, size) < 0)
        err = errno_map();
    close(fd);
    return err;
}

int realfs_setattr(struct mount *mount, const char *path, struct attr attr) {
    if (realfs_is_readonly(mount))
        return _EROFS;
    if (attr.type == attr_size)
        return realfs_truncate(mount, path, attr.size);
    int fd = realfs_open_beneath(mount, path, O_RDONLY, 0);
    if (fd < 0)
        fd = realfs_open_beneath(mount, path, O_WRONLY, 0);
    if (fd < 0)
        return errno_map();
    int err;
    switch (attr.type) {
        case attr_uid:
            err = fchown(fd, attr.uid, -1);
            if (err < 0 && errno == EPERM)
                err = 0; // silently ignore, we're not root on host
            break;
        case attr_gid:
            err = fchown(fd, attr.gid, -1);
            if (err < 0 && errno == EPERM)
                err = 0;
            break;
        case attr_mode:
            err = fchmod(fd, attr.mode);
            break;
        default:
            close(fd);
            TODO("other attrs");
    }
    int saved_errno = errno;
    close(fd);
    errno = saved_errno;
    if (err < 0)
        return errno_map();
    return err;
}

int realfs_fsetattr(struct fd *fd, struct attr attr) {
    if (realfs_is_readonly(fd->mount))
        return _EROFS;
    int real_fd = fd->real_fd;
    int err;
    switch (attr.type) {
        case attr_uid:
            err = fchown(real_fd, attr.uid, -1);
            if (err < 0 && errno == EPERM)
                return 0;
            break;
        case attr_gid:
            err = fchown(real_fd, attr.gid, -1);
            if (err < 0 && errno == EPERM)
                return 0;
            break;
        case attr_mode:
            err = fchmod(real_fd, attr.mode);
            break;
        case attr_size:
            err = ftruncate(real_fd, attr.size);
            break;
        default: abort();
    }
    if (err < 0)
        return errno_map();
    return err;
}

int realfs_utime(struct mount *mount, const char *path, struct timespec atime, struct timespec mtime) {
    if (realfs_is_readonly(mount))
        return _EROFS;
    struct timespec times[2] = {atime, mtime};
    char leaf[NAME_MAX + 1];
    int parent_fd = realfs_parent_fd(mount, path, leaf);
    if (parent_fd < 0)
        return errno_map();
    int err = utimensat(parent_fd, leaf, times, AT_SYMLINK_NOFOLLOW);
    int saved_errno = errno;
    close(parent_fd);
    errno = saved_errno;
    if (err < 0)
        return errno_map();
    return 0;
}

int realfs_mkdir(struct mount *mount, const char *path, mode_t_ mode) {
    if (realfs_is_readonly(mount))
        return _EROFS;
    char leaf[NAME_MAX + 1];
    int parent_fd = realfs_parent_fd(mount, path, leaf);
    if (parent_fd < 0)
        return errno_map();
    int err = mkdirat(parent_fd, leaf, mode);
    int saved_errno = errno;
    close(parent_fd);
    errno = saved_errno;
    if (err < 0)
        return errno_map();
    return 0;
}

int realfs_flock(struct fd *fd, int operation) {
    int real_op = 0;
    if (operation & LOCK_SH_) real_op |= LOCK_SH;
    if (operation & LOCK_EX_) real_op |= LOCK_EX;
    if (operation & LOCK_UN_) real_op |= LOCK_UN;
    if (operation & LOCK_NB_) real_op |= LOCK_NB;
    return flock(fd->real_fd, real_op);
}

int realfs_statfs(struct mount *mount, struct statfsbuf *stat) {
    // Do not project host capacity through Apple's required-reason disk-space
    // APIs. The guest only needs stable filesystem geometry; Learnfold owns
    // its actual course quotas in the native supervisor.
    (void)mount;
    stat->bsize = 4096;
    stat->blocks = 131072;
    stat->bfree = 65536;
    stat->bavail = 65536;
    stat->files = 100000;
    stat->ffree = 50000;
    stat->namelen = NAME_MAX;
    stat->frsize = 4096;
    return 0;
}

int realfs_mount(struct mount *mount) {
    // Open the caller-supplied directory before canonicalizing it. Calling
    // realpath(3) first follows a final symlink, leaving a race in which an
    // untrusted writable source (such as the course workspace) can redirect
    // the mount outside its intended root.
    mount->root_fd = open(mount->source, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (mount->root_fd < 0)
        return errno_map();

    char source_path[MAX_PATH];
    if (platform_fd_get_path(mount->root_fd, source_path, sizeof(source_path)) < 0) {
        int saved_errno = errno;
        close(mount->root_fd);
        mount->root_fd = -1;
        errno = saved_errno != 0 ? saved_errno : EIO;
        return errno_map();
    }
    char *canonical_source = strdup(source_path);
    if (canonical_source == NULL) {
        close(mount->root_fd);
        mount->root_fd = -1;
        return _ENOMEM;
    }
    free((void *) mount->source);
    mount->source = canonical_source;
    return 0;
}

static int realfs_umount(struct mount *mount) {
    if (mount->root_fd < 0)
        return 0;
    int result = close(mount->root_fd);
    mount->root_fd = -1;
    if (result < 0)
        return errno_map();
    return 0;
}

int realfs_fsync(struct fd *fd) {
    int err = fsync(fd->real_fd);
    if (err < 0)
        return errno_map();
    return 0;
}

int realfs_getflags(struct fd *fd) {
    int flags = fcntl(fd->real_fd, F_GETFL);
    if (flags < 0)
        return errno_map();
    return open_flags_fake_from_real(flags);
}

int realfs_setflags(struct fd *fd, dword_t flags) {
    int ret = fcntl(fd->real_fd, F_SETFL, open_flags_real_from_fake(flags));
    if (ret < 0)
        return errno_map();
    return 0;
}

ssize_t realfs_ioctl_size(int cmd) {
    if (cmd == FIONREAD_)
        return sizeof(dword_t);
    if (cmd == TCGETS_)
        return sizeof(struct termios_);
    if (cmd == TIOCGWINSZ_)
        return sizeof(struct winsize_);
    return -1;
}

int realfs_ioctl(struct fd *fd, int cmd, void *arg) {
    int err;
    size_t nread;
    switch (cmd) {
        case FIONREAD_:
            err = ioctl(fd->real_fd, FIONREAD, &nread);
            if (err < 0)
                return errno_map();
            *(dword_t *) arg = nread;
            return 0;
        case TCGETS_:
            // For piped stdio fds backed by a real host TTY, return a
            // plausible termios so that musl isatty() succeeds.
            if (isatty(fd->real_fd)) {
                struct termios host_termios;
                if (tcgetattr(fd->real_fd, &host_termios) == 0) {
                    struct termios_ *guest = (struct termios_ *)arg;
                    memset(guest, 0, sizeof(*guest));
                    guest->iflags = host_termios.c_iflag;
                    guest->oflags = host_termios.c_oflag;
                    guest->cflags = host_termios.c_cflag;
                    guest->lflags = host_termios.c_lflag;
                    return 0;
                }
            }
            return _ENOTTY;
        case TIOCGWINSZ_: {
            // libuv calls TIOCGWINSZ during uv_tty_init to get terminal size.
            if (isatty(fd->real_fd)) {
                struct winsize host_ws;
                if (ioctl(fd->real_fd, TIOCGWINSZ, &host_ws) == 0) {
                    struct winsize_ *guest_ws = (struct winsize_ *)arg;
                    guest_ws->row = host_ws.ws_row;
                    guest_ws->col = host_ws.ws_col;
                    guest_ws->xpixel = host_ws.ws_xpixel;
                    guest_ws->ypixel = host_ws.ws_ypixel;
                    return 0;
                }
            }
            return _ENOTTY;
        }
    }
    return _ENOTTY;
}

const struct fs_ops realfs = {
    .name = "real", .magic = 0x7265616c,
    .mount = realfs_mount,
    .umount = realfs_umount,
    .statfs = realfs_statfs,

    .open = realfs_open,
    .readlink = realfs_readlink,
    .link = realfs_link,
    .unlink = realfs_unlink,
    .rmdir = realfs_rmdir,
    .rename = realfs_rename,
    .symlink = realfs_symlink,
    .mknod = realfs_mknod,

    .close = realfs_close,
    .stat = realfs_stat,
    .fstat = realfs_fstat,
    .setattr = realfs_setattr,
    .fsetattr = realfs_fsetattr,
    .utime = realfs_utime,
    .getpath = realfs_getpath,
    .flock = realfs_flock,

    .mkdir = realfs_mkdir,
};

const struct fd_ops realfs_fdops = {
    .read = realfs_read,
    .write = realfs_write,
    .pread = realfs_pread,
    .pwrite = realfs_pwrite,
    .readdir = realfs_readdir,
    .telldir = realfs_telldir,
    .seekdir = realfs_seekdir,
    .lseek = realfs_lseek,
    .mmap = realfs_mmap,
    .poll = realfs_poll,
    .ioctl_size = realfs_ioctl_size,
    .ioctl = realfs_ioctl,
    .fsync = realfs_fsync,
    .close = realfs_close,
    .getflags = realfs_getflags,
    .setflags = realfs_setflags,
};
