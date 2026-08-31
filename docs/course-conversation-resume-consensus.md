# Course Conversation Resume and Unapproved Plan Persistence

## 1. Status and consensus date

- **Status:** Agreed
- **Consensus date:** 2026-08-16
- **Final revision:** 1
- **Decision scope:** Learnfold iOS course creation and the shared Rust submission boundary

## 2. Executive decision

An unfinished course creation flow is a durable, on-device **Course Draft**, not a transient “New Course” screen. It survives normal app termination and app updates until it becomes a saved course or the learner explicitly discards it.

The draft restores the conversation locator and transcript when available, the protected presented-plan revision and explicit approval state, the editable learner message, and valid source references. A presented but unapproved plan remains **Not approved** after relaunch, reconnect, retry, migration, or thread replacement. Only an explicit approval gesture for the current protected plan revision can approve it.

Message recovery is state-specific. **Try Again** is allowed only when non-acceptance is authoritative. If a request may have been dispatched but its acknowledgement is missing, Learnfold shows **Check Status** and reconciles before allowing another send. It never silently resends work whose acceptance is unknown.

## 3. Problem, users, and evidence

The reported TestFlight-update experience restored the earlier course conversation and plan revision, then showed:

> Codex couldn’t send that yet. Your message and sources are still here—try again.

The composer was blank and the only action was **Dismiss**. This proves that course restoration mostly succeeded; it does not prove why the subsequent transport attempt failed.

Source inspection confirms three defects:

1. The store durably records workspace, runtime, server, thread, model, plan, plan visibility, pending text, and sources in [`CourseExperienceStore.swift`](../apps/ios/Sources/Litter/Models/CourseExperienceStore.swift#L2251), and restores them on launch in the same file at [the draft restoration path](../apps/ios/Sources/Litter/Models/CourseExperienceStore.swift#L2386).
2. A failed attempt restores the learner text into `courseChatDraft` and preserves the outbound journal in [`restoreUnacceptedSubmission`](../apps/ios/Sources/Litter/Models/CourseExperienceStore.swift#L5844). However, `CourseChatView` copies that draft into its private `inputText` only during [`onAppear`](../apps/ios/Sources/Litter/Views/CourseChatView.swift#L773), after [`sendCurrentMessage`](../apps/ios/Sources/Litter/Views/CourseChatView.swift#L941) already cleared the visible field. An asynchronous failure while the view remains mounted is therefore invisible.
3. Leaving the screen with that blank field invokes [`saveDraft`](../apps/ios/Sources/Litter/Models/CourseExperienceStore.swift#L3224), which can clear `pendingOutboundText`. The projection defect can therefore become actual message loss. The generic [`CourseAgentErrorCard`](../apps/ios/Sources/Litter/Views/CourseChatView.swift#L1096) also has no retry/status action for this state even though the generated copy says “try again.”

Existing tests verify cold-launch restoration of pending Codex plan/thread and outbound text/sources in [`CourseExperienceStoreTests.swift`](../apps/ios/Tests/LitterTests/CourseExperienceStoreTests.swift#L2039), and assert the reported error copy at [line 4162](../apps/ios/Tests/LitterTests/CourseExperienceStoreTests.swift#L4162). They do not verify same-view composer projection, navigation after failure, or acknowledgement-ambiguity recovery.

The exact transport/auth/thread error is unknown. The physical iPhone was unavailable during this investigation, and the screenshot contains deliberately generic copy rather than the logged error domain/code. No transport root-cause claim is part of this decision.

## 4. Outcomes and success measures

The experience must:

- preserve unfinished course work through termination and TestFlight/App Store updates;
- make the learner’s actual message, sources, plan revision, and approval state visibly trustworthy;
- prevent implicit approval, implicit discard, silent replacement, and duplicate sends;
- give one recovery action that matches the known system state;
- keep a full plan readable without clipping or truncation.

Measure:

- cold-launch/update draft-restore success rate;
- restored-composer projection latency;
- migration success rate;
- known-safe retry-to-acceptance rate;
- recovered-draft continuation rate;
- acknowledgement-ambiguity rate and reconciliation result;
- duplicate prevention and failure-to-abandonment rate;
- invariant `implicit_pending_clear == 0`, with every pending clear attributed to authoritative acceptance or explicit discard.

## 5. Scope and non-goals

### In scope

- iOS course creation before and through plan approval;
- one active Course Draft in the initial UI, identified by a stable workspace ID;
- relaunch/update restoration, navigation safety, retry/reconnect/status recovery;
- versioned migration from the current singleton draft payload;
- the narrow shared Rust state needed for authoritative submission phases and reconciliation;
- accessibility, Dynamic Type, scroll, logging, and focused tests for these states.

### Non-goals

- Android UI, Android parity, or Android QA;
- a multi-draft library in this delivery;
- cross-device conversation sync, recovery after uninstall/device loss, or a cloud-storage promise;
- automatic plan approval, automatic discard, or automatic resend;
- resurrecting a deleted remote thread;
- claiming the reported transport failure is fixed without its raw error evidence.

User-facing persistence language is **Saved on this device**.

## 6. End-to-end experience flow

1. **Create or continue:** A new course creates a stable workspace-backed Course Draft. If one active draft already exists, New Course offers **Continue Existing Draft** or confirmed **Discard & Start New**.
2. **Plan presented:** The protected current plan is shown in full with `Plan ready for review · Revision N · Not approved`.
3. **Leave safely:** Back saves and leaves; it never discards. Explicit discard names the conversation, plan, unsent message, and source references that will be removed.
4. **Restore after interruption/update:** If the draft screen was the last route before involuntary interruption, restore it once with **Draft restored**. After the learner intentionally backs out, later launches land normally and show **Continue Course Draft**.
5. **Restore placement:** Keep the keyboard closed. Preserve a valid scroll anchor; otherwise reveal the plan header. A compact recovery status above the composer exposes any unsent or uncertain message.
6. **Known not accepted:** Restore exact text and valid sources into the visible editable composer. Show **Message not sent** and **Try Again** only if dispatch definitely did not occur or an authoritative rejection proves non-acceptance.
7. **Acceptance unknown:** Show **We couldn’t confirm whether your message was sent** and **Check Status**. Reconcile before enabling another send.
8. **Accepted/processing:** Show progress or **Resume**; hydrate the existing turn and never resend it.
9. **Auth/readiness failure:** Preserve everything and show **Sign In** or **Reconnect**.
10. **Thread missing:** Preserve local draft and protected plan, then offer **Continue in New Conversation**. Bind the replacement thread transactionally, seed saved context, and never replay approval.
11. **Approve:** **Approve Plan** applies only to the currently displayed protected revision. Consequence text explains that approval prepares the course map and Chapter 1; the button does not promise atomic generation when the agent is offline.

## 7. UX and accessibility requirements

- Use the known course title as the navigation title with a visible **Course Draft** status; fall back to **Course Draft**.
- Treat course lifecycle and message delivery as orthogonal states. A message error must not make the valid unapproved plan look corrupt.
- The composer is the visible recovery surface: restored text is editable and source chips are individually labelled and removable.
- Editing restored content persists immediately, supersedes the previous retry payload, and changes **Try Again** to ordinary **Send**.
- **Not Now** may collapse an expanded notice but leaves a compact durable status such as `Not sent · Draft restored` or `Status unknown · Draft preserved`.
- In-session failure announces `Message not sent. Draft restored.` once and focuses the notice, not the keyboard. Cold restoration does not steal VoiceOver focus or reopen the keyboard.
- Status is never conveyed by color alone. Plan revision and approval state have complete accessibility labels.
- Support VoiceOver, Reduce Motion, increased contrast, RTL, landscape, and the largest Dynamic Type sizes with a logical focus order and at least 44-point targets.

## 8. UI direction, content, components, and all states

Keep transcript, full plan, and recovery content in one outer vertical scroll. Do not clip plan text and do not place a nested vertical scroll inside the plan card. The sticky composer must not cover the last plan or action row.

Place one compact recovery surface immediately above the composer. Avoid stacked generic error cards. At large text sizes, actions stack vertically and cards grow without fixed heights.

| Canonical recovery state | Heading/status | Primary action | Secondary behavior |
|---|---|---|---|
| `editing` | Draft saved | Send | Leave safely |
| `submitting` | Sending… | Progress/Stop when supported | No duplicate tap |
| `knownNotAccepted` | Message not sent | Try Again | Not Now; composer remains editable |
| `acceptanceUnknown` | We couldn’t confirm whether your message was sent | Check Status | Not Now; no resend |
| `acceptedProcessing` | Codex is working / reply loading | Resume or Check Conversation | No resend |
| auth required | Sign in to continue | Sign In | Draft preserved |
| server unavailable | Course agent is offline | Reconnect | Draft preserved |
| missing thread | Conversation unavailable | Continue in New Conversation | Draft and plan preserved |

Plan UI shows the full revision label and **Not approved** or **Approved**. For an unapproved offline plan, recovery replaces or disables approval and explains why. For an already-approved offline plan, show **Approved** plus **Reconnect to Create Chapter 1**; never request approval again.

## 9. Technical design and ownership boundaries

### Canonical records

Create a schema-versioned `CourseDraft` record per workspace containing:

- workspace/draft ID and timestamps;
- runtime/server/thread/model locator;
- current protected presented-plan ID and revision;
- approval projection derived from protected approval artifacts, never `showsBrief` or a workspace mirror;
- course lifecycle: `planning`, `planReady(revision, notApproved)`, `approvedGenerating`, or `ready`;
- pending-submission journal and source locators;
- last-route restoration intent and migration metadata.

The pending journal contains a stable client submission ID, workspace/thread, content and source locators, server baseline, attempt count, last typed failure, and phase: `editing`, `submittingPreDispatch`, `dispatchedAwaitingAck`, `knownNotAccepted`, `acceptanceUnknown`, `accepted(turnID)`, or `settled`.

Write the journal atomically before dispatch. Clear it only after authoritative acceptance/settlement or explicit discard. View disappearance and an empty SwiftUI field cannot clear it.

### Ownership

- Shared Rust `AppStore`/client owns canonical thread, dispatch, acceptance, and reconciliation state.
- The iOS course repository owns Course Draft product state and protected presented/approved plan artifacts.
- SwiftUI is a thin live projection. Remove destructive `takeDraft` mirroring or replace it with an explicit store-driven update that cannot overwrite a newer journal.
- `UserDefaults` is only the active-workspace/last-route index, not the authoritative draft record.

A stable `client_user_message_id` should be carried across the boundary for correlation, but it must not be described as idempotency until server deduplication or fail-closed reconciliation is proven.

## 10. Data, privacy, security, performance, and reliability

- Keep draft text and local source references in protected app storage; preserve existing workspace isolation and file validation.
- Retain the active draft on-device until explicit discard or successful conversion into a saved course.
- Never log learner text, source names, URLs, file paths, or file contents.
- Logs may include build/schema, runtime, typed error domain/code, journal phase, chosen action, reconciliation result, plan revision/approval boolean, and salted hashed workspace/thread/submission IDs.
- Restore local content immediately; network reconciliation runs without hiding the plan or composer.
- Source references that no longer resolve are marked unavailable and can be removed or replaced without deleting message text.
- Thread replacement must verify workspace and protected-plan identity and fail closed on mismatch.

## 11. Edge cases and failure recovery

- **Process death at any send boundary:** journal-first writes preserve state before dispatch, after dispatch/before acknowledgement, and after acknowledgement/before clear.
- **Blank composer after async restore:** live store projection repopulates it; navigation cannot persist the blank mirror over pending content.
- **Repeated taps/relaunch retry:** guard locally and reconcile across processes; at most one logical accepted learner turn, or fail closed with status unknown.
- **Delayed acceptance after apparent failure:** correlation converts unknown to accepted and hydrates; never duplicate.
- **Expired auth/offline server/runtime incompatibility:** preserve draft/plan and show typed recovery.
- **Missing or replaced thread:** create a new thread only after explicit action; preserve plan revision and unapproved state.
- **Newer plan revision:** reconcile protected artifacts, show one current approval CTA, and never approve a stale revision.
- **Approved locally but generation send fails:** retain Approved and offer reconnect/resume, not approval again.
- **Missing source:** mark only that source unavailable; keep other sources and text.
- **Corrupt or legacy record:** quarantine invalid data, retain recoverable legacy bytes, and surface a diagnostic ID.
- **Account/workspace change:** never attach a draft silently to another identity.

## 12. Delivery sequence and dependencies

1. **Data-loss hotfix:** prevent `onDisappear`/empty composer state from clearing a pending journal; live-project restored text/sources into the mounted composer; make Dismiss/Not Now non-destructive; keep the full plan scrollable and untruncated.
2. **Truthful recovery UI:** conservatively classify any post-dispatch/no-receipt failure as `acceptanceUnknown`; add typed state-specific actions and accessibility behavior.
3. **Durable Course Draft v1:** add per-workspace versioned record, active pointer, last-route intent, atomic migration, explicit discard, and Continue Course Draft entry.
4. **Shared reconciliation:** add narrow Rust-owned persisted dispatch/recovery phases, stable correlation, thread-read reconciliation, and typed Swift projection.
5. **Exactly-once hardening:** add server deduplication or prove fail-closed reconciliation before advertising post-dispatch retry.

The data-loss hotfix and conservative Check Status UX do not depend on exactly-once support.

## 13. Verification and acceptance criteria

- A same-screen known-pre-dispatch failure restores exact text and every valid source before showing recovery UI; no duplicate optimistic learner bubble remains.
- Leaving, backgrounding, killing, relaunching, updating, dismissing, or choosing Not Now cannot clear pending content.
- Cold launch/update restores the correct workspace/thread, transcript when available, full plan revision, explicit approval state, message, and sources.
- An unapproved plan never becomes approved or starts generation without explicit approval of the current protected revision.
- `knownNotAccepted`, `acceptanceUnknown`, `acceptedProcessing`, auth, readiness, and missing-thread states each show the specified copy/action.
- Retry is unavailable when acceptance is unknown. Retry/Resume produces at most one logical accepted turn across timeout and process-death boundaries, or fails closed.
- Legacy migration is atomic, repeatable, verified before pointer switch, and retains legacy bytes on failure.
- Starting a new course cannot silently overwrite the active draft.
- Full plans, long messages, five or more sources, and all actions remain readable at maximum Dynamic Type, VoiceOver, dark mode, increased contrast, Reduce Motion, RTL, and landscape.
- Tests cover process death before journal, after journal/before RPC, after dispatch/before acknowledgement, after acknowledgement/before clear, and during streaming.

## 14. Rollout, observability, and rollback

Roll out behind a schema/version gate. First ship the non-destructive hotfix and conservative recovery classification, then migrate durable records, then enable richer reconciliation actions.

Monitor restore/migration success, recovery state distribution, ambiguity, duplicate prevention, and the `implicit_pending_clear` invariant by build. Provide a copyable diagnostic ID for support without exposing content.

If migration or typed reconciliation regresses, stop creating new-format records, continue reading verified records, retain legacy bytes, and fall back to **Draft preserved · Check Status**. Rollback must never convert unknown work to retryable or approved.

## 15. Risks and mitigations

- **Duplicate turns after lost acknowledgement:** withhold resend, correlate and reconcile, add server idempotency before stronger promises.
- **Actual text loss from SwiftUI/store divergence:** make the journal authoritative and forbid view lifecycle clears.
- **Stale thread/server after update:** typed validation, reconnect, and explicit replacement-thread flow.
- **Plan approval drift:** protected current-revision artifacts are authoritative; fail closed on mismatch.
- **Migration corruption:** atomic write/read verification, idempotent migrator, quarantine, and legacy retention.
- **Sensitive local retention:** protected storage, explicit discard, on-device wording, content-free telemetry.
- **Restoration trap on every launch:** restore the interrupted route once; after intentional Back use Continue Course Draft.

## 16. Decisions, rejected alternatives, and resolved disagreements

- **Chosen:** one active Course Draft in the MVP UI with a stable per-workspace record. **Rejected:** a singleton-shaped record or a full multi-draft library now.
- **Chosen:** one-time interrupted-route restoration plus Continue Course Draft. **Rejected:** forcing the draft open on every launch.
- **Chosen:** state-specific Try Again, Check Status, Resume, Sign In, Reconnect, and Continue in New Conversation. **Rejected:** a universal Try Again or Dismiss-only recovery.
- **Chosen:** full plan in one page scroll. **Rejected:** truncation, fixed-height plan cards, or nested vertical scrolling.
- **Chosen:** editable restored composer with no separate Edit button.
- **Chosen:** `Approve Plan` with separate consequence text. **Rejected:** an approval CTA that promises atomic Chapter 1 generation before that guarantee exists.
- **Chosen:** revision requests remain submission actions until an authoritative plan revision exists. **Rejected:** a speculative durable `revisionRequested` course phase.
- **Chosen:** local on-device retention until explicit discard/course conversion. **Rejected:** language implying cloud or cross-device recovery.

## 17. Assumptions and non-blocking open questions

- The exact reported transport failure remains unknown; capture raw device/app-server error domain/code on a future reproduction.
- Confirm whether the deployed app-server exposes a stable client submission ID in hydrated turns and whether true idempotent `turn/start` can be added.
- Define the reconciliation timeout that distinguishes delayed visibility from a typed missing thread; until then, fail closed.
- Confirm source permission durability after update and the exact record archival/deletion point after successful course creation.
- A future multi-draft library can use the per-workspace record/index without changing this experience contract.

## 18. Consensus record

The same Product, UX, UI, and Engineering council completed one independent-position round, one cross-examination round, and one ratification round. Key changes during deliberation were: restricting Try Again to authoritative non-acceptance, separating one-time route restoration from perpetual auto-open, changing one draft to one active draft with extensible identity, removing a redundant Edit action, and avoiding an approval CTA that overpromises atomic generation.

All four roles explicitly approved revision 1 on 2026-08-16:

- **Product — APPROVE:** The brief captures the durable Course Draft promise, explicit unapproved-plan protection, conservative acknowledgement recovery, non-destructive retention, one-time route restoration, extensible one-active-draft scope, and measurable outcomes.
- **UX — APPROVE:** The brief makes restored content visible and non-destructive, separates route restoration from perpetual auto-open, limits retry to authoritative non-acceptance, reconciles unknown acceptance, and defines coherent copy, accessibility, retention, and discard behavior.
- **UI — APPROVE:** The brief specifies the full untruncated single-scroll plan, live composer restoration, state-specific recovery, explicit approval state, non-destructive notice collapse, and concrete Dynamic Type, VoiceOver, and scroll criteria.
- **Engineering — APPROVE:** The brief separates confirmed SwiftUI/journal defects from the unknown transport cause, fails closed after ambiguous dispatch, preserves protected approval, assigns canonical submission state to Rust, and defines implementable migration, privacy, and test invariants.
