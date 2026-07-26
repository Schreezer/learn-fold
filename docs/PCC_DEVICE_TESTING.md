# Private Cloud Compute device tests

Learnfold's PCC tests run in a separate, opt-in XCTest target. They require a
signed physical device on iOS 27, the Xcode 27 SDK, internet access, Apple
Intelligence, the PCC entitlement on `com.chirag.learnfold`, and remaining
per-user PCC quota.

Set Xcode and run the lightweight Aeon smoke test:

```bash
export DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer
./apps/ios/scripts/test-pcc-on-device.sh --smoke
```

Available modes:

- `--preflight`: availability and quota only; performs no inference.
- `--smoke`: preflight plus a minimal streaming text response.
- `--tools`: preflight plus a required synthetic, side-effect-free tool call.
- `--course-plan`: preflight plus Learnfold's real course-plan tool boundary.
- `--all`: runs every diagnostic and consumes the most PCC quota.

The device defaults to `Aeon`. Override it with `PCC_DEVICE_NAME`:

```bash
PCC_DEVICE_NAME="My iPhone" ./apps/ios/scripts/test-pcc-on-device.sh --tools
```

Each run writes an `.xcresult`, an `xcodebuild` log, a JSON summary, and exported
XCTest attachments under `artifacts/pcc-device-tests/<timestamp>/`. Attachments
include device/OS availability, quota state, first-output and total latency,
response length/preview, exact error type, and tool-call arguments.

These are live integration tests, not deterministic unit tests. A failure after
the request reaches PCC can indicate Apple beta framework/service availability
rather than a Learnfold regression. Run `--preflight` first, then the narrowest
inference test needed.
