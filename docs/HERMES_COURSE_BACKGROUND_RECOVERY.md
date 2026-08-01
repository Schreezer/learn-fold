# Hermes course background execution and recovery

Last updated: 2026-08-01

## Goal

Learnfold should allow a learner to start a course-generation job, leave the
app, and later return without losing work or repeating a native editor
mutation. If iOS terminates Learnfold or the learner force-quits it, the app
cannot promise that its process will keep running. It must instead resume the
course job from a durable, verified boundary.

The intended product guarantee is:

> Continue in the background when iOS permits it, and durably resume from the
> exact safe tool boundary after suspension or termination.

## Runtime boundary

The Hermes course flow spans two independent runtimes:

1. Hermes reasons and produces responses on the user's VPS.
2. Learnfold executes approval-gated `native-editor-*` tools against the
   course database on the iPhone.
3. Learnfold returns the verified tool result to Hermes.
4. Hermes either requests another tool or finishes the turn.

Hermes can continue an already-started inference while the phone is
disconnected. It cannot directly mutate the iPhone's course database. A
Hermes response containing `learnfold_tool_call` therefore waits until
Learnfold is running and able to execute that tool.

## Current behavior

### Foreground

The foreground Hermes flow is implemented and verified on both simulator and a
signed physical iPhone:

- Learnfold selects a paired Hermes server.
- Hermes presents an approval-gated course plan.
- Learnfold executes native editor tools locally.
- Tool results are sent back to the same Hermes thread.
- Completed course pages and their revisions persist in the native course
  database.

#### Live simulator validation (2026-07-31)

The production-shaped local stack was exercised through the Learnfold UI on
an iPhone 17 Pro simulator running iOS 27.0. This was not a mocked provider
test:

- Kittylitter ran the pinned Alleycat Hermes bridge and connected to the local
  authenticated Hermes gateway.
- A learner created and approved the `Mobile Tool Loop` plan in the app.
- Hermes emitted `present_course_plan`, `native-editor-fetch`, and
  `native-editor-update-page` calls. Learnfold executed them against the
  simulator-owned native course database.
- Every returned envelope included `executed_on: mobile_device`, the original
  call ID, source turn ID, and workspace ID. Hermes consumed each result in a
  subsequent `/v1/runs` request before choosing the next action.
- The app rendered the resulting lesson, including its fenced Swift example,
  and persisted it at revision 3 with `generation_status: generated`.
- The Kittylitter launch service was deliberately restarted. Its durable
  Hermes binding and 12 completed turns were restored, the app reattached to
  the same thread, and a learner follow-up completed as turn 13. The durable
  turn store ended with no active run and no pending submission intent.
- The app process was then terminated and relaunched. `My Courses` restored
  the generated course, its transcript, and the editable native lesson.

The signed simulator test lane also passed 21 focused Hermes lifecycle tests,
including fresh-process pre-accept and accepted-turn disk recovery, plus 3
cloud/KVS tests and 4 continued-processing lifecycle tests on iOS 26.5.
The exact published Alleycat pin passed all 51 `alleycat-hermes-bridge` tests
and all 48 `alleycat` tests from a clean detached checkout. Kittylitter was
then rebuilt with `--locked` from that pin and its launch service restarted.
The upgrade migrated the existing 13-turn Hermes thread into Kittylitter's
application-specific state directory without changing its thread/session IDs;
the directory is mode `0700`, both journal files are mode `0600`, and the
durable active-run and submission-intent maps remained empty.

This proves foreground phone-owned execution, result return, durable daemon
restart, app relaunch, and thread continuity in simulators. It does not prove
that iOS grants or preserves a continued-processing task on a physical device.

### App moved to the background

`AppModel.startTurn` requests a `BGContinuedProcessingTask` for a
user-initiated turn. iOS may allow the process to continue, while Learnfold
reports progress through the system-owned Live Activity.

This is best-effort:

- The system may reject, queue, expire, or terminate the background task.
- The simulator reports `BGTaskSchedulerErrorDomain error 1`; real background
  execution requires a signed physical-device test.
- A Hermes course job may contain several turns because every native tool
  result is returned to Hermes in a new turn.
- The current background controller keeps one per-thread continued-processing
  lease alive across those Hermes response and tool-result turns. An
  intermediate idle snapshot or a failed attempt to start a later result turn
  does not close the lease.
- Only the learner action that starts or approves the job may create that
  lease. Automatic tool-result and cold-recovery turns can reuse an existing
  lease, but never submit a new `BGContinuedProcessingTaskRequest` without a
  fresh person action.
- A terminal course response, explicit recovery abandonment, learner Stop,
  definitive forward failure, or system expiration closes the lease exactly
  once. The system presentation identifies the worker as Hermes.

This lifecycle is covered by controller-level simulator tests, including
active-to-idle reuse, one scheduler request across later result turns,
intermediate start failure, explicit finish, and expiration/interrupt. Actual
iOS scheduling reliability remains best-effort, but the signed physical-device
happy path below now proves one accepted continued-processing request through a
real background interval and the complete phone-owned tool/result chain.

If iOS merely suspends the process rather than terminating it, the in-memory
Swift task is frozen. On foreground return, Learnfold reconnects saved servers,
refreshes authoritative thread state, and the existing task can continue.

### App terminated or force-quit

All in-process Swift and Rust tasks stop. A swipe-to-kill does not reliably
invoke `applicationWillTerminate`, so the Alleycat connection may close
without a graceful handshake.

The course tool loop now has durable, fail-closed recovery:

- `PendingHermesCourseIdentity` and `PendingHermesAcceptedTurn` persist the
  exact workspace, server, thread, runtime, model, brief, and accepted turn.
- `remote-hermes-tool-journal.json` is atomically replaced in the workspace's
  `.course` directory. It records the source turn, canonical arguments,
  execution/result-delivery phase, locally produced result, correlated result
  turn, retry count, and durable 24-step chain budget.
- Relaunch restores the exact workspace/thread, fetches authoritative turn
  state, resumes unsent results, and reconciles a ready course before allowing
  its workspace to be abandoned.
- Confirmed failed/interrupted result turns roll back only the delivery phase;
  the native mutation is never repeated. Each explicit recovery attempt
  resubmits the stored result with the same call identifier and records the
  cumulative attempt count.
- Corrupt journals, timeouts, unknown turn state, and interrupted mutating-tool
  execution fail closed instead of guessing.
- A response that contains the exact `"learnfold_tool_call"` marker but is not
  one strict bare JSON envelope is never rendered as ordinary prose and is
  never executed. Learnfold persists the protocol error as terminal recovery
  evidence, keeps the course/thread locator, and requires the learner to
  explicitly abandon that failed response before continuing from the saved
  course. Choosing Retry re-surfaces the same durable error rather than polling
  a nonexistent turn or entering an indefinite thinking state.

`UserDefaults` is used only as a small course/thread navigation pointer. Before
any Hermes turn RPC, Learnfold atomically writes the submission baseline, full
submitted payload, linked-source metadata, and optimistic message identity to
`remote-hermes-submissions.json` inside the course workspace. For a new course,
that same record carries the workspace, server, thread, runtime/model, brief,
and presentation state, so a cold launch can recover without either
`UserDefaults` recovery key. The accepted turn ID replaces that record
synchronously after the RPC returns. When a native tool row takes ownership,
the submission record changes to an explicit tool-lifecycle locator instead of
being deleted; it remains until the complete tool/result chain is terminal or
the learner explicitly abandons it. Device-side state changes refresh this
identity synchronously; in particular, displaying `present_course_plan`
persists the exact brief and approval visibility before its result is sent.
Tool
execution/result delivery lives beside it in
`remote-hermes-tool-journal.json`; canonical remote turns remain owned by the
shared Rust client. Existing `UserDefaults` recovery records are migrated into
the workspace journal once and then removed.

## Important transaction boundary

The JSON journals and the course SQLite editor mutation are two durable stores,
not one database transaction. Learnfold writes `.executing` before invoking a
mutation and `.executed` afterward. A crash after SQLite commits the page but
before the JSON journal reaches `.executed` is therefore deliberately reported
as an ambiguous mutation. Learnfold does not replay it and returns a
needs-attention/fetch-state result when recovery continues.

This prevents duplicate mutations, but it is not the stronger guarantee that
every locally committed mutation result will eventually be delivered as a
successful result. Achieving that guarantee requires moving the tool receipt
and idempotency record into the same SQLite transaction as the editor mutation.
Until then, this crash window is an explicit production limitation rather than
an exactly-once claim.

## Hermes server compatibility boundary

Learnfold Link pins Alleycat revision
`e2edae8061c1ab6f7af255ef3d6583c6605159bd`. The reviewed Hermes Runs
implementation is fork revision
`95574e945cea3c404e6bc36be695634c14e0b9c7`, rebased on upstream
`5835201de19b099d76b8e4c64afe8af90c98af05`, and proposed upstream as
`NousResearch/hermes-agent#75519`.

The bridge does not trust a version string. It authenticates to the loopback
Hermes API and requires the complete Runs/session capability contract,
including `run_submission_idempotency`, before it accepts mobile turns. Stock
or custom Hermes builds that do not advertise that contract fail closed.
Learnfold Link intentionally does not overwrite the learner's existing Hermes
installation; until the upstream patch is released, operators must deploy the
reviewed fork revision for this lane.

Hermes keeps the idempotency replay map in memory and prunes terminal entries
after one hour. This is intentionally a bounded, same-process submission
recovery contract for Alleycat's immediate identical retry after a lost HTTP
response. It is not durable idempotency across a Hermes restart and must not be
described as such.

## Implemented journal phases

- `executing`
- `executed`
- `resultSubmitting`
- `resultSubmitted`
- `completed`
- `abandoned` (only after an explicit learner confirmation; evidence remains)

Every external result submission is preceded by an atomic phase write. A
completed result turn closes the journal row. A confirmed failed/interrupted
result turn can safely return to `executed`; ambiguous outcomes retain their
existing evidence.

## Idempotent tool execution

For each `learnfold_tool_call`:

1. Canonicalize and validate its arguments.
2. Validate the active `workspace_id` and approved plan revision.
3. Insert the tool call into the journal with a local receipt UUID. Duplicate
   detection uses the stable `(sourceTurnID, toolName)` identity, and a
   conflicting call at that identity fails closed.
4. If a receipt already exists, do not execute the mutation again.
5. Execute with `expected_revision` or an equivalent compare-and-swap guard.
6. Commit the editor mutation.
7. Atomically record the result in the JSON journal. This is not the same
   transaction as step 6; see the limitation above.
8. Send a `learnfold_tool_result` containing the same tool-call identifier.
9. Mark delivery only after the remote turn accepts the result.

If Learnfold dies after step 7 but before step 9, relaunching resends the stored
result and does not reapply the editor mutation. If it dies between steps 6
and 7, recovery fails closed because commit status is ambiguous.

If execution status is ambiguous, read the page revision and checksum before
deciding whether to retry.

## Cold-launch recovery

On launch or foreground return:

1. Restore the pending Hermes course identity and accepted-turn pointer.
2. Reconnect the saved Alleycat/PersonalClaw server.
3. Reattach to the exact persisted Hermes thread through the shared Rust
   client.
4. Fetch authoritative turns, including the newest completed assistant turn.
5. Compare remote thread state with `remote-hermes-tool-journal.json`.
6. Continue according to its exact phase; replay only read-only execution,
   resend recorded results without repeating mutations, and retain ambiguous
   evidence.
7. Reconcile generated course pages and mark the run complete only after the
   native course database proves readiness.

Recovery should not depend on the previous Swift `Task` still existing.

## Background task ownership

The continued-processing task belongs to a complete `CourseAgentRun`, not one
server turn.

- Start it directly from the learner action that starts or approves the job.
- Keep it alive across Hermes response and tool-result turns.
- Report progress from durable phase changes and editor receipts.
- Do not declare the background task complete merely because one Hermes turn
  became idle.
- On expiration, close the system task and interrupt the exact active upstream
  turn. Durable accepted-turn and journal pointers remain available for
  foreground recovery.
- Do not assume iOS will relaunch Learnfold after a force-quit.

If the background allowance expires while Hermes is reasoning, it is safe to
let that server-side inference finish because a returned native tool call
cannot mutate the phone by itself. Learnfold can retrieve the response later.

## Learner-facing states

The course UI should distinguish:

- **Continuing on PersonalClaw**
- **Continuing in the background**
- **Paused — reopen Learnfold to continue**
- **Waiting for approval**
- **Needs attention**
- **Course ready**

After a cold launch, an unfinished job should reappear on the home screen
instead of becoming an invisible workspace directory.

## Signed physical-device validation (2026-08-01)

The production-shaped Hermes lane completed on Aeon, an iPhone 17 Pro Max
running iOS 27.0 (24A5390f). CoreDevice inventory identifies the installed app
as developer-built `com.chirag.learnfold` version 1.5.0, build 1. Raw
`codesign` evidence for the matching deployed local artifact verifies its
designated requirement, CDHash, Apple Development authority, and team
`UF4L3PL7UG`. CoreDevice does not expose an installed-binary signing team or
hash, so that signing evidence is correlated by bundle ID, version, and build
rather than claimed as an independent hash of the installed binary. Hermes
used the `learnfoldflawless` profile and the reviewed `/v1/runs`
implementation.

The final fresh `Final Mobile Result Chain` workspace was first moved to the
background immediately after its initial plan response completed, then again
for 20 seconds while course generation held an active tracked turn. The second
interval is the background-continuation proof: device logs show the
user-initiated continued-processing request, `existingTrackedTurnCount: 1` on
background entry, successful background-turn completion, foreground recovery
of the exact thread, and the final lesson becoming visible.

The exported journal contains exactly six successful phone-owned calls with
one delivery attempt each: `present_course_plan`, `native-editor-fetch(self)`,
root fetch, chapter fetch, lesson fetch, and one `native-editor-update-page`.
Every result is correlated to the next Hermes turn with
`executed_on: mobile_device`. The single mutating call uses
`expected_revision: 1`, commits revision 2, and atomically changes the lesson
content and `generation_status` to `generated`; the exported SQLite page and
returned tool result agree. The strict verifier returned
`artifact_consistency_verified` with six calls, six returned results, no
pending phone submissions, and no pending remote runs.

CoreDevice's native `screen-record` command is unsupported on this device/OS
combination. Direct XCTest device recording works while Learnfold stays in the
foreground, but backgrounding disconnects that runner; Apple Device Hub also
contends with the automation session for the screen service. Consequently the
trusted evidence boundary is explicit: direct physical screenshots/foreground
media identify the exact course, while timestamped device logs and hashed
course/Kittylitter exports corroborate the background interval and tool/result
chain. A trusted reviewer combines those artifacts with raw device identity
and signing evidence; the strict verifier checks artifact consistency but does
not authenticate that provenance by itself.

## Verification plan

### Unit tests

- Every valid run-state transition.
- Duplicate tool-call insertion.
- Crash after editor commit but before result delivery.
- Duplicate result delivery.
- Stale `expected_revision`.
- Workspace or approval-revision mismatch.
- Recovery of a completed Hermes response.
- Recovery when the remote turn is still active.
- Recovery when the remote thread no longer exists.

### Simulator tests

The simulator can validate persistence and relaunch logic, but not actual
`BGContinuedProcessingTask` runtime:

1. Start a Hermes course run.
2. Terminate the process at each journal boundary.
3. Relaunch the app.
4. Verify the same workspace, thread, tool call, and page revision resume.
5. Verify no editor mutation is applied twice.

Inject termination at these boundaries:

- after receiving a tool call;
- after recording `executing_tool`;
- after committing the page mutation;
- after recording the receipt;
- after sending the result;
- after Hermes finishes but before course completion is persisted.

### Physical-device tests

Use a signed iPhone on iOS 26 or later:

1. Start a multi-tool Hermes course run and background Learnfold.
2. Confirm the system continued-processing Live Activity remains accurate.
3. Leave the app backgrounded through multiple Hermes tool turns.
4. Return and verify the course finished without duplicate mutations.
5. Repeat while allowing the system task to expire.
6. Repeat with swipe-to-kill during every journal boundary.
7. Relaunch and verify exact continuation and final course persistence.

## Acceptance criteria

- Backgrounding does not end the job at the first Hermes turn boundary.
- Force-quitting never causes a native tool mutation to execute twice.
- Relaunching restores the exact pending plan, tool call, receipt, or Hermes
  response.
- A partially completed job remains visible to the learner.
- A completed remote response cannot be lost solely because Learnfold was not
  running when it arrived.
- Course readiness is derived from verified native document state.
- Simulator persistence tests and signed-device background tests both pass.

The source implementation, simulator lanes, and one signed physical-device
happy-path run satisfy the core background-continuation and no-duplicate
criteria. Expiration and swipe-to-kill injection at every journal boundary are
still release-hardening work, so this document does not claim unrestricted
iOS scheduling, durable idempotency across a Hermes restart, or exactly-once
delivery across the SQLite-commit/JSON-journal crash window described above.

## Current code references

- `apps/ios/Sources/Litter/Models/AppModel.swift`
  - starts or reuses the user-initiated continued-processing request.
- `apps/ios/Sources/Litter/Models/ContinuedTurnBackgroundController.swift`
  - owns per-thread multi-turn background task scheduling, terminal closure,
    and expiration.
- `apps/ios/Sources/Litter/Models/AppLifecycleController.swift`
  - tracks backgrounded turns, push wakes, reconnect, and foreground
    reconciliation.
- `apps/ios/Sources/Litter/Models/CourseExperienceStore.swift`
  - owns the current Hermes response/tool loop, course persistence, and ready
    workspace recovery.
- `apps/ios/Sources/Litter/LitterApp.swift`
  - owns scene-phase hooks and best-effort Alleycat shutdown.
- `shared/rust-bridge/codex-mobile-client/src/mobile_client/`
  - owns authoritative thread resume and runtime reconciliation.

## Apple references

- [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados/)
- [`BGContinuedProcessingTask`](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
- [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
