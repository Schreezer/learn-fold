use anyhow::{Context, bail};
#[cfg(unix)]
use std::ffi::CStr;
use std::fs;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::ffi::OsStringExt;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::process::Stdio;
use std::time::{Duration, Instant};
use url::Url;

const HERMES_API_BASE: &str = "http://127.0.0.1:8642";

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
    let hermes = prepare_hermes_gateway()?;

    let executable = std::env::current_exe().context("locate learnfold-link executable")?;
    // The bare invocation is Alleycat's complete onboarding path: it installs
    // user-level autostart when possible, starts/upgrades the daemon, and
    // prints a fresh pairing payload. Capture that payload so the model never
    // has to inspect or relay the credential itself.
    let payload = managed_pairing_payload(&executable, &hermes.home)?;
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

struct HermesGateway {
    home: PathBuf,
}

fn prepare_hermes_gateway() -> anyhow::Result<HermesGateway> {
    if let Some(gateway) = running_hermes_gateway() {
        return Ok(gateway);
    }

    let home = selected_hermes_home().context("locate the active Hermes profile")?;
    fs::create_dir_all(&home)
        .with_context(|| format!("create Hermes profile directory {}", home.display()))?;
    let env_path = home.join(".env");
    let existing = fs::read_to_string(&env_path).unwrap_or_default();
    let generated_key = random_api_key();
    let (updated, api_key) = updated_hermes_env(&existing, &generated_key);
    write_private_file(&env_path, updated.as_bytes())
        .with_context(|| format!("configure Hermes API in {}", env_path.display()))?;

    if !authenticated_gateway_ready(&api_key) {
        let status = Command::new("hermes")
            .args(["gateway", "install", "--force"])
            .env("HERMES_HOME", &home)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .context("run the installed Hermes command")?;
        if !status.success() {
            bail!("Hermes could not install its local gateway service");
        }

        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            if authenticated_gateway_ready(&api_key) {
                return Ok(HermesGateway { home });
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        bail!("Hermes gateway did not become ready");
    }

    Ok(HermesGateway { home })
}

fn running_hermes_gateway() -> Option<HermesGateway> {
    hermes_home_candidates().into_iter().find_map(|home| {
        let existing = fs::read_to_string(home.join(".env")).ok()?;
        let api_key = dotenv_value(&existing, "API_SERVER_KEY")?;
        authenticated_gateway_ready(&api_key).then_some(HermesGateway { home })
    })
}

fn authenticated_gateway_ready(api_key: &str) -> bool {
    let Ok(client) = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
    else {
        return false;
    };
    client
        .get(format!("{HERMES_API_BASE}/api/sessions?limit=1"))
        .bearer_auth(api_key)
        .send()
        .is_ok_and(|response| response.status().is_success())
}

fn selected_hermes_home() -> Option<PathBuf> {
    hermes_home_candidates().into_iter().next()
}

fn hermes_home_candidates() -> Vec<PathBuf> {
    if let Some(home) = std::env::var_os("HERMES_HOME")
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty())
    {
        return vec![home];
    }

    if let Some(shell_home) = std::env::var_os("HOME").map(PathBuf::from)
        && shell_home.file_name().is_some_and(|name| name == "home")
        && let Some(profile_home) = shell_home.parent()
        && profile_home.join("profile.yaml").is_file()
    {
        return vec![profile_home.to_path_buf()];
    }

    let Some(root) = os_account_home().map(|home| home.join(".hermes")) else {
        return Vec::new();
    };
    hermes_home_candidates_from_root(&root)
}

fn hermes_home_candidates_from_root(root: &Path) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(profile) = fs::read_to_string(root.join("active_profile")) {
        let profile = profile.trim();
        if !profile.is_empty() && profile != "default" {
            let profile_home = root.join("profiles").join(profile);
            if profile_home.is_dir() {
                candidates.push(profile_home);
            }
        }
    }
    candidates.push(root.to_path_buf());

    if let Ok(entries) = fs::read_dir(root.join("profiles")) {
        let mut profiles = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.is_dir())
            .collect::<Vec<_>>();
        profiles.sort();
        candidates.extend(profiles);
    }
    candidates.dedup();
    candidates
}

fn updated_hermes_env(existing: &str, generated_key: &str) -> (String, String) {
    let api_key = dotenv_value(existing, "API_SERVER_KEY")
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| generated_key.to_string());
    let settings = [
        ("API_SERVER_ENABLED", "true"),
        ("API_SERVER_KEY", api_key.as_str()),
        ("API_SERVER_HOST", "127.0.0.1"),
        ("API_SERVER_PORT", "8642"),
    ];
    let mut seen = std::collections::HashSet::new();
    let mut lines = existing
        .lines()
        .map(|line| {
            let key = dotenv_key(line);
            if let Some((name, value)) = settings.iter().find(|(name, _)| key == Some(*name)) {
                seen.insert(*name);
                format!("{name}={value}")
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>();
    for (name, value) in settings {
        if seen.insert(name) {
            lines.push(format!("{name}={value}"));
        }
    }
    (format!("{}\n", lines.join("\n")), api_key)
}

fn dotenv_key(line: &str) -> Option<&str> {
    let line = line.trim().strip_prefix("export ").unwrap_or(line.trim());
    let (key, _) = line.split_once('=')?;
    Some(key.trim())
}

fn dotenv_value(contents: &str, wanted: &str) -> Option<String> {
    contents.lines().find_map(|line| {
        (dotenv_key(line) == Some(wanted)).then(|| {
            let line = line.trim().strip_prefix("export ").unwrap_or(line.trim());
            let (_, value) = line.split_once('=').expect("dotenv key has an equals sign");
            let value = value.trim();
            value
                .strip_prefix('"')
                .and_then(|value| value.strip_suffix('"'))
                .or_else(|| {
                    value
                        .strip_prefix('\'')
                        .and_then(|value| value.strip_suffix('\''))
                })
                .unwrap_or(value)
                .to_string()
        })
    })
}

fn random_api_key() -> String {
    use rand::RngCore;

    let mut bytes = [0_u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(unix)]
fn write_private_file(path: &Path, contents: &[u8]) -> anyhow::Result<()> {
    let temporary = path.with_extension(format!("env.learnfold-{}", std::process::id()));
    let mut file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(contents)?;
    file.sync_all()?;
    fs::rename(temporary, path)?;
    Ok(())
}

#[cfg(not(unix))]
fn write_private_file(path: &Path, contents: &[u8]) -> anyhow::Result<()> {
    fs::write(path, contents)?;
    Ok(())
}

fn managed_service_command(executable: &Path, hermes_home: &Path) -> Command {
    let mut command = Command::new(executable);
    command.env("HERMES_HOME", hermes_home);

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

fn managed_pairing_payload(
    executable: &Path,
    hermes_home: &Path,
) -> anyhow::Result<serde_json::Value> {
    for attempt in 0..2 {
        let output = managed_service_command(executable, hermes_home)
            .output()
            .context("set up the local Learnfold Link service")?;
        if output.status.success()
            && let Ok(stdout) = String::from_utf8(output.stdout)
            && let Ok(payload) = pairing_payload_from_output(&stdout)
        {
            return Ok(payload);
        }
        if attempt == 0 {
            std::thread::sleep(Duration::from_millis(250));
        }
    }
    bail!("Learnfold Link could not create a pairing credential")
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

    #[test]
    fn hermes_env_preserves_other_settings_and_reuses_key() {
        let existing =
            "MODEL=claude\nexport API_SERVER_KEY=\"existing-secret\"\nAPI_SERVER_PORT=9999\n";
        let (updated, key) = updated_hermes_env(existing, "new-secret");

        assert_eq!(key, "existing-secret");
        assert!(updated.contains("MODEL=claude\n"));
        assert!(updated.contains("API_SERVER_ENABLED=true\n"));
        assert!(updated.contains("API_SERVER_KEY=existing-secret\n"));
        assert!(updated.contains("API_SERVER_HOST=127.0.0.1\n"));
        assert!(updated.contains("API_SERVER_PORT=8642\n"));
    }

    #[test]
    fn hermes_candidates_include_running_profiles_without_an_active_marker() {
        let root =
            std::env::temp_dir().join(format!("learnfold-hermes-candidates-{}", random_api_key()));
        let alpha = root.join("profiles/alpha");
        let zeta = root.join("profiles/zeta");
        fs::create_dir_all(&alpha).unwrap();
        fs::create_dir_all(&zeta).unwrap();

        let candidates = hermes_home_candidates_from_root(&root);
        assert_eq!(candidates, vec![root.clone(), alpha, zeta]);

        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn managed_service_uses_account_home_and_selected_hermes_profile() {
        let hermes_home = Path::new("/tmp/hermes-profile");
        let command = managed_service_command(Path::new("/tmp/learnfold-link"), hermes_home);
        let configured_home = command
            .get_envs()
            .find_map(|(key, value)| (key == "HOME").then_some(value))
            .flatten()
            .map(PathBuf::from);
        let configured_hermes_home = command
            .get_envs()
            .find_map(|(key, value)| (key == "HERMES_HOME").then_some(value))
            .flatten()
            .map(PathBuf::from);
        assert_eq!(configured_home, os_account_home());
        assert_eq!(configured_hermes_home.as_deref(), Some(hermes_home));
    }
}
