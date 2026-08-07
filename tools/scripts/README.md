# Shared Scripts (Planned)

Cross-platform automation scripts will move here over time.

- `build-android-rust.sh`: builds Android Rust bridge JNI libs into `apps/android/core/bridge/src/main/jniLibs`.
- `codex-app-driver.applescript`: launches `Codex.app`, opens a project root, creates a thread, and pastes/sends prompts through GUI scripting for desktop-side conversation automation.
- `codex-desktop-controller.mjs`: launches or attaches to a remote-debugging-enabled `Codex.app` instance, then drives the real renderer UI through CDP so it can open projects, create threads, send prompts, wait for the turn to finish, and dump the visible transcript as JSON without macOS accessibility scripting.
- `deploy-android-ondevice.sh`: builds Rust JNI libs, assembles `onDeviceDebug`, installs on a target device (`--serial`/`ANDROID_SERIAL`), and launches the app.
- `switch-app-identity.sh`: switches local app IDs between `com.sigkitten.litter` and `com.<your-identifier>.litter` for Android+iOS (`--to your-identifier --identifier <name>`), with optional `--team-id` for iOS signing. For iOS it updates `apps/ios/project.yml` and regenerates `apps/ios/Litter.xcodeproj` via `xcodegen` (no direct `.xcodeproj` edits).
- `triage-mobile-feedback.py`: rerunnable triage ledger for GitHub issues/PRs, TestFlight feedback/crashes, and Google Play reviews/crash issues. It stores raw per-run snapshots, a durable local state file, and a generated board under `artifacts/mobile-triage/`.
- `verify-hermes-device-lifecycle.py`: joins a fresh exported iPhone course workspace, a point-in-time Kittylitter bridge snapshot, and a hashed candidate device-run manifest. It fails closed unless every Hermes tool envelope is journaled one-to-one, every result is correlated as `executed_on: mobile_device`, and the approved fetch/update chain matches the native SQLite document, including any post-mutation fetch when present. Its pass is artifact-consistency evidence, not authenticated device provenance.

Hermes signed-device evidence:

```bash
swift build \
  --package-path shared/third_party/NativeBlockEditor \
  --product native-editor-evidence-helper
NATIVE_HELPER="$(swift build \
  --package-path shared/third_party/NativeBlockEditor \
  --show-bin-path)/native-editor-evidence-helper"

./tools/scripts/verify-hermes-device-lifecycle.py \
  /path/to/capture/export/Apps/Courses/<workspace-id> \
  --bridge-state /path/to/capture/hermes-bridge \
  --run-manifest /path/to/capture/run-manifest.json \
  --expected-model learnfoldflawless \
  --expected-bundle-id com.chirag.learnfold \
  --native-helper "$NATIVE_HELPER"
```

The manifest must hash every input plus a physical-device screen recording,
final screenshot, raw `devicectl` device/app JSON, raw `codesign` output, and
normalized device/app/signing JSON. The normalized records must contain
`raw_sha256` equal to the corresponding raw artifact hash. Capture the raw
inputs directly rather than copying terminal tables:

```bash
xcrun devicectl device info details \
  --device "$DEVICE_UDID" \
  --json-output "$CAPTURE/device-info.raw.json"
xcrun devicectl device info apps \
  --device "$DEVICE_UDID" \
  --bundle-id com.chirag.learnfold \
  --json-output "$CAPTURE/app-info.raw.json"
xcrun devicectl device capture screenshot \
  --device "$DEVICE_UDID" \
  --destination "$CAPTURE/final.png"
```

On the Aeon iOS 27.0 lane, CoreDevice reports that device screen recording is
unsupported. Use a trusted Apple Device Hub Mac-side recording when the whole
background/foreground transition must be visible, or use `agent-device record`
for a direct physical-device recording while its XCTest session remains in the
foreground. Device Hub and the XCTest runner contend for the same device-screen
service, so do not claim that an automated uninterrupted Device Hub recording
proves background execution. Bind foreground media to the exact run through
the course title and manifest hashes, and use timestamped app logs plus the
exported journal for the background interval:

```bash
agent-device record start "$CAPTURE/lifecycle.mp4" \
  --scope device --session "$AGENT_DEVICE_SESSION"
# Open the completed course that belongs to this capture.
agent-device record stop --session "$AGENT_DEVICE_SESSION"
```

The verifier checks the phone journals, exact approved plan and learner
approval, contiguous result-turn chain, terminal Hermes response, exact
model/binding policy, real SQLite schema/hierarchy/history integrity and
receipt-table presence, the production Swift store and
`NotionEnhancedMarkdownCodec` projection, the Swift example, and final course
state. It accepts the current production
`search`/`fetch` discovery sequence and requires a revision-checked atomic
`replace_content` or `update_content` mutation whose committed page result
matches SQLite; an additional post-mutation fetch, when present, must match the
same revision and Markdown exactly. It is intentionally limited to a fresh
proof workspace.

Its success status is `artifact_consistency_verified`. This status proves only
that the captured files agree. It does **not** authenticate that editable JSON
came from CoreDevice or prove that the lifecycle timestamps correspond to the
video. A trusted reviewer must inspect the raw `devicectl` outputs, code-signing
identity, recording, and timestamped device logs before making a physical-device
or background-execution claim. If the transition is not visible in the media,
the reviewer must require the device logs to show the active tracked turn at
backgrounding, foreground recovery, and terminal completion. Synthetic unit
fixtures exercise the fail-closed consistency rules only and are never device
proof. Media validation requires `ffprobe` (`brew install ffmpeg`) and the
native Swift helper built above.

Mobile triage flow:

```bash
# Fetch GitHub issues/PRs + TestFlight + Play data for the last day and update the local board.
./tools/scripts/triage-mobile-feedback.py --last-hours 24

# Inspect active items without fetching again.
./tools/scripts/triage-mobile-feedback.py list --status active

# Mark work as handled so repeated fetches do not put it back in the active queue.
./tools/scripts/triage-mobile-feedback.py mark '<item-id>' --status done --note 'Fixed in <commit-or-version>'
./tools/scripts/triage-mobile-feedback.py mark '<item-id>' --status pr-open --note 'Fix PR #123'
```

The generated board is `artifacts/mobile-triage/triage-board.md`; the source of truth is `artifacts/mobile-triage/triage-state.json`.

Common `codex-desktop-controller.mjs` flows:

```bash
# Launch a separate Codex instance with Electron remote debugging enabled.
node tools/scripts/codex-desktop-controller.mjs launch \
  --app "/Applications/Codex copy.app" \
  --port 9333 \
  --user-data-dir /tmp/codex-desktop-controller-profile

# Reuse that same instance on later commands. Add --fresh-launch only if you
# intentionally want a brand new app instance on the same port/profile setup.
node tools/scripts/codex-desktop-controller.mjs thread-state --port 9333 --launch

# Attach to an already-running automation instance and inspect the active thread.
node tools/scripts/codex-desktop-controller.mjs thread-state --port 9333

# Send one turn into the current thread, wait for the assistant to finish, and print JSON.
node tools/scripts/codex-desktop-controller.mjs run-turn \
  --port 9333 \
  --message 'Reply with exactly: OK'

# Start a fresh thread in a sidebar project, run the first turn, and print the final transcript.
node tools/scripts/codex-desktop-controller.mjs run-turn \
  --port 9333 \
  --project codex-test \
  --message 'Reply with exactly: OK'
```
