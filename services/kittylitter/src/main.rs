use anyhow::{Context, bail};
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
    let output = Command::new(executable)
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
}
