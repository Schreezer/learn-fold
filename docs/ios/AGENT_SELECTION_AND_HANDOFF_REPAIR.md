# Agent Selection and Handoff Repair

Updated: 2026-08-04

This is the working ledger for the Aeon device repair pass. Status and evidence are updated as each item is implemented, reviewed, and verified.

## Scope

| ID | Problem | Expected behavior | Owner | Status |
| --- | --- | --- | --- | --- |
| LF-1 | Course details opened on Structure | Workspace-backed courses open on Learn by default | Root | Complete; two review rounds clean |
| LF-2 | Choosing Codex could continue to use Hermes | A Codex tap checks the local Codex runtime and authentication before changing the selection; failure or cancellation preserves the prior provider | Codex selection subagent | Complete; four review rounds clean |
| LF-3 | Hermes Telegram setup lost its continuation and asked for a newly copied prompt | Leaving Learnfold for Telegram must not invalidate a valid pending handoff; recovery must distinguish a real expired/failed handoff from an app lifecycle or transient network interruption | Hermes iOS and broker subagents | Implemented, deployed, and reviewed; real Telegram acceptance pending |
| LF-4 | Device may still contain an older build | Build current sources, replace the installed app on Aeon, launch it, and record exact install/launch/runtime evidence | Root | Complete; current signed build installed and launched |

## Product rules being preserved

- Agent Settings controls the default provider for newly created courses.
- Existing courses retain the provider/runtime that owns their conversation; the UI must state this clearly instead of implying an existing Hermes course was migrated.
- Codex selection must use a local server and must never be validated through a remote Hermes server.
- Authentication cancellation and failed credentials are non-destructive: the previously selected provider remains selected.
- No Android work is included in this repair.

## Review-loop checklist

- [x] LF-1: default Learn landing — two rounds with the same reviewer; no important actionable findings.
- [x] LF-2: Codex auth-gated selection — four rounds with the same reviewer; all correctness, UX, security, and coverage findings resolved.
- [x] LF-3: Hermes Telegram handoff — broker review converged after two rounds; iOS review converged after three rounds.

## Verification evidence

### LF-1 — Default Learn landing

- Source: `CourseDetailView` initializes its section to `learn`.
- Simulator: existing course opened with Learn selected and the learning path visible.
- Screenshot: `/tmp/learnfold-default-learn/05-course-default-learn.png`.
- Review loop: two rounds; no important findings. A dedicated UI-test assertion was noted as optional and declined for this pass because the signed runtime check directly covers the one-line initial-state change.
- Physical device: after the reinstall, an existing course opened with Learn selected and the learning path visible. Screenshot: `/tmp/learnfold-aeon-default-learn.png`.

### LF-2 — Codex selection

- Codex always resolves to the local iPhone server; the selected remote Hermes server cannot satisfy validation.
- Tapping Codex runs a live non-billable credential check before moving the draft checkmark. ChatGPT/agent identity uses authenticated rate limits; API-key/custom providers use typed Rust `GET /models` with a 10-second timeout and redirects disabled.
- Save failure rolls the draft back to the persisted provider/model/effort. Catalog loading preserves an unavailable persisted choice instead of auto-selecting unvalidated Codex.
- Provider configuration loads from Keychain with propagating errors before any provider request. Unreadable or partial URL/key configuration fails closed; sensitive errors are hidden; a custom key cannot fall back to OpenAI because its URL read failed.
- Swift verification: 6/6 focused tests passed. xcresult: `/tmp/learnfold-codex-selection-derived/Logs/Test/Test-Litter-2026.08.04_22-52-04-+0530.xcresult`.
- Rust verification: 4/4 deterministic loopback HTTP probe tests passed twice, covering 2xx, 401/403, exact base-path joining, redirect refusal/no bearer forwarding, and bounded timeout. No external network was used.
- Review loop: four rounds. All important findings were implemented; the fourth round found no remaining important issue.
- Physical device: Course Settings shows Codex selected and the local Codex model catalog loaded; a new-course screen reports `Codex connected`. Screenshot: `/tmp/learnfold-aeon-settings.png`.
- Physical proof boundary: the Settings sheet was readable but its controls were marked covered by the physical-device automation runner, so this pass did not obtain a trustworthy fresh tap-to-check credential challenge. The success/failure/cancellation gate is proven by the focused Swift and Rust tests above, not by that screenshot.

### LF-3 — Hermes Telegram handoff

- Confirmed iOS root cause: the polling loop treated every thrown error, including transient network loss and task cancellation, as terminal. It cleared the still-valid request ID and claim token and forced a new prompt.
- Confirmed lifecycle gaps: pending state existed only in SwiftUI memory, foreground resume was not handled, and a cancelled stale polling task could clear a newer request.
- Confirmed broker gap: claim data was consumed before the response was safely received, so response loss made an otherwise successful handoff impossible to retry.
- Broker source fix: an authorized, unexpired claim can return the same immutable pairing payload again after response loss. Explicit authorized cancellation or the original expiry alarm removes it.
- Broker verification: `npm test` passed 6/6; `npm run check` and `git diff --check` passed.
- Broker review loop: two rounds. The first found missing cleanup coverage; cancel/alarm tests were added. The second found no important remaining issue.
- Cloudflare Workers review: checked against current Workers types and official Durable Object storage/alarm behavior; the existing 2026-07-28 compatibility date means `deleteAll()` also removes its alarm.
- Deployment: Cloudflare Worker version `6d2703ec-4478-4c4e-8772-a203639b4eb5` deployed to the production broker.
- Production smoke: create `201`, submit `202`, first claim `200`, identical retry claim `200`, authorized cancel `200`, replay after cancel `401`. No credentials were printed.
- iOS repair: pending request and claim token persist in Keychain; backgrounding pauses and foregrounding resumes; transient poll/claim failures retain the same request with bounded retry; every async completion is request-ID guarded; replacement is transactional; credential and pending-Keychain failures are visible and recoverable; a successful connection clears only its matching request and acknowledges the broker without blocking.
- iOS recovery UI: after claim succeeds but parsing/agent loading loses network, Review remains available and retries the same secure request rather than forcing a new prompt.
- iOS verification: `HermesPairingLifecycleCoordinatorTests` passed 13/13 with zero failures; parse and diff checks passed. xcresult: `/tmp/learnfold-hermes-dd-canonical/Logs/Test/Test-Litter-2026.08.04_22-42-16-+0530.xcresult`.
- iOS review loop: three rounds. Round 1 fixed six lifecycle/security/UX races; round 2 fixed the missing post-claim retry affordance; round 3 found no important remaining issue.
- Remaining proof boundary: the rebuilt app is on Aeon, but the complete leave-for-Telegram, return-to-Learnfold, and deliberate transient-network acceptance run still requires the real Telegram participant.

### LF-4 — Aeon installation

- Before this repair pass, Aeon (`D9AC3A68-8FAB-5625-AAEA-EE4EE716AF70`) had Learnfold 1.5.0 (1) installed and running.
- `make ios-device-fast` completed with `** BUILD SUCCEEDED **`.
- Signed artifact: `/Users/chirag13/Library/Developer/Xcode/DerivedData/Litter-cmgneiczfvaetieycphpgaeetwig/Build/Products/Debug-iphoneos/Litter.app`; `codesign --verify --deep --strict` passed.
- Artifact metadata: bundle ID `com.chirag.learnfold`, version `1.5.0`, build `1`; executable SHA-256 `671cc16a43e5a0d14c5586f68f617af0879f432d0cd8ab6e06ad7ca85c70c2cb`.
- Aeon install completed at `/private/var/containers/Bundle/Application/7586C6C7-CF22-40DA-9343-6F2E77B86655/Litter.app/`; `devicectl` independently listed Learnfold 1.5.0 (1).
- Launch succeeded; after the physical UI checks, Learnfold was relaunched and observed running as PID `51697`.

## Open risks and decisions

- A successful install and launch is not end-to-end proof of the Telegram handoff. The live broker retry contract and iOS lifecycle behavior are verified separately, while the actual cross-app Telegram round trip remains an explicit acceptance item.
- Existing Hermes courses should not be silently reassigned to Codex because their conversation state belongs to the Hermes runtime. The repaired settings copy must make the new-course boundary explicit.
