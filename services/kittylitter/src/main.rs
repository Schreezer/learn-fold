use anyhow::{Context, bail};
#[cfg(unix)]
use std::ffi::CStr;
#[cfg(unix)]
use std::os::unix::ffi::OsStringExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use url::Url;

fn main() -> anyhow::Result<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if matches!(args.as_slice(), [arg] if arg == "--version" || arg == "-V") {
        println!("learnfold-link {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if args.first().map(String::as_str) == Some("handoff") {
        return run_handoff(&args[1..]);
    }

    alleycat::App {
        binary_name: "learnfold-link",
        qualifier: "com",
        organization: "sigkitten",
        // Preserve the existing state and service identity so upgrading from
        // kittylitter does not orphan pairings or create a second daemon.
        application: "kittylitter",
        label: "com.sigkitten.kittylitter",
        version: env!("CARGO_PKG_VERSION"),
    }
    .run()
}

fn run_handoff(args: &[String]) -> anyhow::Result<()> {
    let [submit_url] = args else {
        bail!("usage: learnfold-link handoff <one-time-submit-url>");
    };
    validate_submit_url(submit_url)?;

    let executable = std::env::current_exe().context("locate learnfold-link executable")?;
    // The bare invocation is Alleycat's complete onboarding path: it installs
    // user-level autostart when possible, starts/upgrades the daemon, and
    // prints a fresh pairing payload. Capture that payload so the model never
    // has to inspect or relay the credential itself.
    let output = managed_service_command(&executable)
        .output()
        .context("set up the local Learnfold Link service")?;
    if !output.status.success() {
        bail!("Learnfold Link could not create a pairing credential");
    }

    let stdout =
        String::from_utf8(output.stdout).context("read Learnfold Link pairing response")?;
    let payload = pairing_payload_from_output(&stdout)?;
    let response = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .context("prepare secure pairing handoff")?
        .post(submit_url)
        .json(&payload)
        .send()
        .context("submit the pairing credential to Learnfold")?;

    if !response.status().is_success() {
        bail!(
            "Learnfold rejected the pairing handoff (HTTP {})",
            response.status().as_u16()
        );
    }

    println!("Pairing sent securely. Return to Learnfold and approve the connection.");
    Ok(())
}

fn managed_service_command(executable: &Path) -> Command {
    let mut command = Command::new(executable);

    // Hermes profiles intentionally give terminal tools an isolated HOME.
    // launchd/systemd start user services with the OS account's real HOME,
    // though, so allowing Alleycat's onboarding to inherit the profile HOME
    // splits the CLI and daemon across different state directories. The CLI
    // then pairs a fallback daemon whose identity is not the managed service.
    //
    // Learnfold Link is an OS-user service, not Hermes profile state. Normalize
    // only the onboarding child to the account home so install, IPC, identity,
    // and autostart all resolve to the same persistent location.
    if let Some(home) = os_account_home() {
        command.env("HOME", home);
        #[cfg(target_os = "linux")]
        {
            command.env_remove("XDG_CONFIG_HOME");
            command.env_remove("XDG_STATE_HOME");
            command.env_remove("XDG_RUNTIME_DIR");
        }
    }

    command
}

#[cfg(unix)]
fn os_account_home() -> Option<PathBuf> {
    let uid = unsafe { libc::geteuid() };
    let suggested = unsafe { libc::sysconf(libc::_SC_GETPW_R_SIZE_MAX) };
    let capacity = if suggested > 0 {
        suggested as usize
    } else {
        16 * 1024
    };
    let mut buffer = vec![0_u8; capacity];
    let mut passwd = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();

    let status = unsafe {
        libc::getpwuid_r(
            uid,
            passwd.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() {
        return None;
    }

    let passwd = unsafe { passwd.assume_init() };
    if passwd.pw_dir.is_null() {
        return None;
    }
    let bytes = unsafe { CStr::from_ptr(passwd.pw_dir) }.to_bytes().to_vec();
    let home = PathBuf::from(std::ffi::OsString::from_vec(bytes));
    (!home.as_os_str().is_empty()).then_some(home)
}

#[cfg(not(unix))]
fn os_account_home() -> Option<PathBuf> {
    None
}

fn validate_submit_url(raw: &str) -> anyhow::Result<()> {
    let url = Url::parse(raw).context("invalid pairing handoff URL")?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.path().starts_with("/v1/pairing-requests/")
        || !url.path().ends_with("/submit")
        || url
            .query_pairs()
            .all(|(key, value)| key != "token" || value.is_empty())
    {
        bail!("invalid pairing handoff URL");
    }
    Ok(())
}

fn pairing_payload_from_output(output: &str) -> anyhow::Result<serde_json::Value> {
    output
        .lines()
        .find_map(|line| {
            let value = serde_json::from_str::<serde_json::Value>(line).ok()?;
            let object = value.as_object()?;
            (object.contains_key("v")
                && object.contains_key("node_id")
                && object.contains_key("token"))
            .then_some(value)
        })
        .context("Learnfold Link did not return a valid pairing credential")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_one_time_https_submit_url() {
        assert!(
            validate_submit_url(
                "https://litter-pairing-broker.chiragmgg.workers.dev/v1/pairing-requests/abc/submit?token=secret"
            )
            .is_ok()
        );
    }

    #[test]
    fn rejects_insecure_or_unscoped_urls() {
        assert!(
            validate_submit_url(
                "http://litter-pairing-broker.chiragmgg.workers.dev/v1/pairing-requests/abc/submit?token=secret"
            )
            .is_err()
        );
        assert!(validate_submit_url("https://example.com/collect?token=secret").is_err());
    }

    #[test]
    fn extracts_pairing_json_without_exposing_other_output() {
        let payload = pairing_payload_from_output(
            "starting\n{\"v\":1,\"node_id\":\"node\",\"token\":\"secret\"}\nready\n",
        )
        .unwrap();
        assert_eq!(payload["node_id"], "node");
    }

    #[cfg(unix)]
    #[test]
    fn managed_service_uses_os_account_home() {
        let command = managed_service_command(Path::new("/tmp/learnfold-link"));
        let configured_home = command
            .get_envs()
            .find_map(|(key, value)| (key == "HOME").then_some(value))
            .flatten()
            .map(PathBuf::from);
        assert_eq!(configured_home, os_account_home());
    }
}
