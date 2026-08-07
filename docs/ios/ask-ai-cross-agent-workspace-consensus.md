# Ask AI Across Agents in One Course Workspace

Status: Agreed

Consensus date: 2026-08-04
Scope: Learnfold iOS only

## 1. Executive decision

A Learnfold course is a shared native workspace, not a conversation owned by the agent that created it. Selecting a passage and choosing Ask AI starts or reopens a focused discussion whose execution target is independent of the course-origin agent.

- A new focused discussion snapshots the learner's currently selected runtime, server, and effective model.
- Tapping an existing annotation reopens that discussion's persisted target and thread or Apple session.
- Talk to Course Agent and Return to Course Agent remain the explicit ways to resume the course-origin conversation.
- A missing course-origin thread, Apple session, `approved-plan.json`, or `course.json` must not prevent read-only questions when the native workspace and selected page are available.
- Discussion routing, rendering, readiness, authentication, attachments, drafts, stop behavior, and cleanup are scoped to that discussion rather than global course-chat state.

## 2. Problem, users, and evidence

The reported path was: a learner opened the rendered zk-SNARKs course, selected text, and chose Ask AI while Codex was selected. Learnfold displayed “This course is no longer connected to its original agent thread.” The request never reached Codex.

Current source evidence:

- [`CoursePageEditorView`](../../apps/ios/Sources/Litter/Views/CoursePageEditorView.swift) maps every `beginSelectionDiscussion` failure to the same original-thread alert.
- [`CourseExperienceStore`](../../apps/ios/Sources/Litter/Models/CourseExperienceStore.swift) runs `configureCourseAgentContext` before creating a discussion. That requires sidecar course-brief metadata and overwrites the active runtime/server/model/session with course provenance.
- `CourseSelectionDiscussion` persists server/thread/Apple session but not runtime/model, while preparation and display branch on global `activeAgentID`.
- The focused path already knows how to create a fresh app-server thread in the existing workspace when a discussion has no thread, so no new Rust RPC is required.
- `CourseChatView` reads global sources, connection state, authentication state, runtime labels, and capabilities, allowing one conversation scope to leak into another.
- `AppThreadSnapshot` already contains authoritative `agentRuntimeKind` and `model` for legacy binding hydration.

Device evidence from Aeon showed Codex/local as the selected provider while the affected course retained Apple Private Cloud provenance. That mismatch is valid and should work: it is the same mental model as asking different coding agents to work in one folder.

## 3. Outcomes and success measures

1. Original-thread or sidecar absence causes zero Ask AI activation failures when a readable native workspace/page exists.
2. The provider displayed before send always matches the provider that receives the request.
3. Main course chat and every focused discussion have isolated drafts, attachments, readiness, run state, and errors.
4. Existing discussions remain stable across global provider changes and relaunches.
5. The course-origin conversation remains unchanged and independently resumable.
6. Replacement of an exact-range discussion leaves exactly one unresolved annotation and never silently switches providers.

## 4. Scope and non-goals

### In scope

- Swift data model and Codable migration for discussion execution identity and supersession metadata.
- Workspace-only activation for focused chat, with an in-memory title fallback when plan sidecars are absent.
- Typed creation outcomes and failures.
- Discussion-scoped routing/presentation state and attachment/draft isolation.
- Accurate provider identity, inline recovery, exact-anchor conflict UI, and selection-card accessibility.
- Focused XCTest plus simulator and physical-device acceptance.

### Non-goals

- Android parity or Android QA.
- Rebinding or rewriting course-origin provenance.
- New Rust RPCs or generated binding changes.
- Fabricating an approval receipt or bypassing native-editor revision/approval gates.
- A general history browser for resolved selection discussions.
- Multiple stacked, simultaneously tappable annotations over the exact same range.
- Out-of-workspace staging or pre-send confidentiality for imported course sources.

## 5. End-to-end experience flow

### New passage

1. The learner selects a passage and chooses Ask AI.
2. Learnfold forms a stable selection anchor and snapshots the current selected execution target.
3. If no exact unresolved discussion exists, Learnfold creates the focused record and opens the sheet immediately.
4. The sheet says “Ask about this passage,” identifies the bound provider, shows the passage, and prepares the thread/session asynchronously.
5. First send includes the passage envelope once and uses the existing course workspace.

### Existing annotation

1. Tapping the highlight reopens its persisted discussion.
2. Learnfold restores the bound server/thread with turns, or the bound Apple session, regardless of the current global provider.
3. Missing connectivity or authentication appears inline without migration to another provider.

### Exact selection already discussed

- Same normalized target: reopen directly.
- Different or unknown target: show “A discussion already exists.”
- The dialog explains the bound and selected targets and offers:
  - `Continue with <bound>`
  - destructive `Close & Start New with <selected>`
  - Cancel
- Replacement is unavailable while the old scope is running or has unresolved durable Hermes recovery.
- Replacement atomically supersedes the old local row and creates the new row. Remote archive is best-effort and cannot roll back the new discussion.

## 6. UX and accessibility requirements

- Normal new Ask AI remains one tap; no routine confirmation or provider picker.
- Provider identity is visible before the learner can send.
- Failures preserve the passage, draft, attachments, and transcript and provide named recovery such as Sign In to Codex or Reconnect Hermes.
- Never use “original agent thread” copy for focused-discussion creation.
- The passage card exposes the same bounded excerpt preview to sighted and VoiceOver users, announces when more text is available, and provides an accessible `Read full selected passage` action. Full text appears in a scrollable reading view split into manageable accessible paragraphs or chunks; dismissal restores focus to the action. Never place the complete 12,000-character passage in one accessibility label or element.
- The provider badge has a semantic label such as “Discussion agent: Codex, connected.”
- Dynamic Type, landscape, and 44-point interactive targets remain supported.
- Resolve keeps an accessibility hint explaining that it closes the discussion and removes the highlight.

## 7. UI direction, content, components, and states

- Navigation title: `Ask about this passage`.
- Provider badge: existing `AgentIconView`, provider display name, and Connected/Starting/Needs sign-in/Unavailable state. It wraps instead of truncating critical identity.
- Composer placeholder and accessibility label: `Ask a question`.
- Preparation copy: `Starting a Codex discussion…` using the bound provider.
- Existing inline error card is reused with discussion-scoped identity and state.
- Exact-target conflict uses a native confirmation dialog with destructive replacement copy.
- Course-level Talk/Return actions retain their existing labels and course-origin behavior.

## 8. Technical design and ownership boundaries

### Persisted discussion binding

Extend `CourseSelectionDiscussion` with optional, backward-compatible fields:

- `agentRuntimeKind`
- `agentModelID`
- existing `serverID`, `threadID`, and `appleSessionID`
- `supersededByDiscussionID`
- `resolutionReason`
- `remoteArchivePending`

The execution target is Apple provider kind, or app-server runtime + exact server + normalized effective model. The snapshot is captured before workspace activation and is immutable except when authoritative thread metadata hydrates a legacy/default value.

### Scoped execution context

Introduce a Swift `CourseAgentExecutionContext` resolved for main course chat or one `CourseSelectionDiscussion`. Focused prepare/send/readiness/interrupt/resolve/render/source-capability paths use this context, not `currentAgent*` globals. App-server launch accepts the scoped server/model. Rust remains authoritative for server/thread snapshots and RPC state.

### Workspace activation

Split course-origin activation from focused activation:

- Course-origin activation retains the existing provenance/thread behavior and requires the course brief where authoring needs it.
- Focused activation requires a valid saved course and workspace ID. It uses `courseBrief(for:)` when present, otherwise a non-authoritative in-memory display brief derived from `LearningCourse` title/subtitle/duration.
- The fallback is never written as an approved plan and never relaxes editing approval.

### Creation result

Replace the optional creation API with a typed result containing `created`, `reopen`, `targetConflict`, or a precise failure such as workspace unavailable or agent not selected/setup required. Agent connectivity/authentication failures occur after the sheet opens and render inline. Source preparation and recovered drafts serialize only operations within their owning `CourseChatScope`; unrelated scopes do not block focused activation.

### Scope isolation

Store workspace ID, drafts, sources, readiness/authentication, errors, and run state by `CourseChatScope`. Pending outbound recovery already records `pendingSelectionDiscussionID` and is migrated into the corresponding scope. Main chat remains one distinct scope. Focused execution carries its immutable workspace ID without mutating the main chat's `currentCourseWorkspaceID`.

## 9. Data, privacy, security, performance, and reliability

- No selected passage or learner question is added to structured logs.
- Logs may include workspace ID, discussion ID, binding source, runtime ID, server ID, thread ID, and typed error category.
- Permanent remote credentials remain outside course/discussion records.
- Cross-agent access continues through existing workspace mounts or dynamic native-editor tools and workspace ID routing.
- Missing approval permits explanation/read behavior but existing native mutation gates continue to reject edits.
- Scope isolation prevents an attachment from being automatically included in another discussion's outgoing message. Files already committed to the course source directory remain intentionally shared workspace data available to authorized workspace agents.
- Codable additions are optional so existing persisted records still decode.

## 10. Edge cases and failure recovery

- Legacy bound app-server record: read the thread with turns, take authoritative runtime/model from `AppThreadSnapshot`, and persist it. Failure remains bound and unavailable; never guess the current provider. For a newly snapshotted binding, an authoritative runtime/server mismatch is an error rather than permission to rewrite the target; model hydration is limited to legacy or unresolved default-model values.
- Legacy Apple session: infer provider only from valid Apple course provenance. Otherwise show an unknown-binding recovery state.
- Legacy unstarted discussion: bind the current selected target on first open, then persist it.
- Bound thread missing: preserve the record and offer explicit creation of a new discussion; never rewrite history silently.
- Exact-anchor archive failure: leave the old row resolved with `remoteArchivePending`; new discussion remains usable and is never rolled back. Cleanup uses the resolved row's raw persisted server/thread key rather than the unresolved-only lookup helper.
- Active run/Hermes recovery: block destructive replacement until stopped or settled.
- A recovered draft in another scope or workspace remains preserved and does not block focused Ask AI. Block or serialize only source preparation, a pending send, or accepted Hermes/tool recovery owned by the same scope.
- Remote agent cannot mount local path: rely on existing dynamic tools; show capability failure instead of pretending filesystem access.

## 11. Delivery sequence and dependencies

1. Add persisted execution identity, typed outcomes/errors, target comparison, and legacy decoding tests.
2. Split focused workspace activation from course-origin activation and remove the sidecar prerequisite.
3. Route focused prepare/send/interrupt/resolve/thread launch through scoped execution context.
4. Isolate focused drafts, attachments, readiness/authentication, and errors by `CourseChatScope`.
5. Update page conflict handling, provider badge/copy, inline recovery, and selection accessibility.
6. Run focused XCTest and build/install the current artifact for simulator proof.
7. Reproduce Apple-origin course → selected Codex Ask AI on Aeon and verify the authenticated response, annotation reopen, and Return to Course Agent separately.

## 12. Verification and acceptance criteria

- Apple-created course + native database + no plan sidecars + selected connected Codex opens a Codex focused sheet and sends in the same workspace.
- Original `LearningCourse` agent fields are unchanged.
- Selection context is sent exactly once.
- Reopening after provider change restores the discussion-bound provider and transcript.
- Same exact anchor/target reopens without a dialog or duplicate row.
- Different runtime/server/effective model shows the named choice and produces exactly one unresolved marker when replaced.
- Old replacement row is retained with supersession metadata; archive failure leaves cleanup pending without affecting the new discussion.
- Active run/Hermes recovery prevents replacement.
- Legacy payloads decode; authoritative thread hydration persists runtime/model; unknown identity is not guessed.
- Main chat, two focused discussions, and restored pending outbound work cannot see, remove, or automatically send one another's pending composer attachments or drafts. Committed course sources remain shared workspace content.
- With an unsent or recovered main-chat draft in workspace A, focused Ask AI in course workspace B opens and sends without changing workspace A or its draft.
- Provider badge, renderer, source capability, auth state, typing label, stop, and resolve all match actual routing.
- VoiceOver, accessibility text sizes, landscape, and Resolve semantics pass for short, over-preview, and maximum-length selections. The preview is bounded and the full-passage reader exposes manageable chunks and restores focus on dismissal.
- Existing approval/revision tests confirm no mutation bypass.

## 13. Rollout, observability, and rollback

- Ship behind no server migration; the persisted model is additive.
- Add structured creation/preparation categories and remote-cleanup-pending logging without content.
- Monitor Ask AI activation failures, auth failures, unavailable legacy bindings, and pending archive cleanup.
- Rollback can ignore additive fields. Do not delete superseded records during rollback.
- Physical-device acceptance is required before calling the reported Codex path fixed; simulator/build proof alone is insufficient.

## 14. Risks and mitigations

- **Shared mutable globals route to the wrong agent.** Mitigation: scoped execution/presentation context end-to-end.
- **Attachment leakage across providers.** Mitigation: scope sources/drafts and recovery by `CourseChatScope`.
- **Duplicate exact-range annotations orphan history.** Mitigation: one unresolved marker and explicit replacement.
- **Legacy provider cannot be inferred.** Mitigation: authoritative thread hydration or honest unknown state.
- **Read fallback accidentally enables edits.** Mitigation: never synthesize/write approval; keep existing mutation gates.
- **Dirty worktree conflicts.** Mitigation: surgical edits to iOS source/tests only, preserve unrelated changes, inspect diff before every verification boundary.

## 15. Decisions, rejected alternatives, and resolved disagreements

- Rejected rebinding the course itself: it destroys provenance and Return to Course Agent semantics.
- Rejected cloning a workspace per agent: it introduces divergence instead of collaboration.
- Rejected silent fallback to the creator agent: it violates explicit learner selection.
- Rejected copy-only alert fix: it leaves the architectural coupling.
- Rejected unconditional fresh exact-range discussions: current annotation hit testing cannot keep overlapping histories discoverable.
- Rejected unconditional reopen: it silently ignores a selected runtime/server/model change.
- Resolved with full-target comparison and an exceptional Continue versus Close & Start New choice.

## 16. Assumptions and non-blocking open questions

- Resolved/superseded discussion history has no user-facing browser in this release; destructive copy must be honest about closing the old page-linked discussion.
- A later history/stacked-marker design may allow multiple visible discussions on an identical range.
- Remote cleanup retry can initially be opportunistic on launch/open rather than a new background service.

## 17. Consensus record

Round 1: four independent product, UX, UI, and engineering evidence reviews.

Round 2: cross-examination resolved exact-anchor behavior, execution-target normalization, destructive replacement, and scope isolation.

Ratification round 1 identified shared-source privacy wording, cross-workspace draft coupling, and maximum-length VoiceOver blockers.
Ratification round 2 approved the corrected revision unanimously:

- Product: APPROVE — shared workspace and scoped conversation semantics are explicit and testable.
- UX: APPROVE — focused activation, recovery, exact-anchor choice, and accessible reading are coherent.
- UI: APPROVE — provider identity, destructive replacement, scoped state, and VoiceOver behavior are complete.
- Engineering: APPROVE — the Swift-only design preserves runtime ownership, approval gates, migration safety, and verification boundaries.
