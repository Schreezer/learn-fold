# Course Selection Chat — Fix Tracker

Last updated: 2026-07-23

## Goal

When a learner selects text in a course page and chooses **Ask AI**, Learnfold
should open a focused discussion about that passage. The discussion must not
reuse or expose the course-generation conversation. It should remain attached
to the selected passage until the learner resolves it.

## Expected learner flow

1. The learner selects text in a generated course page and taps **Ask AI**.
2. Learnfold creates a new Codex task dedicated to that selection.
3. The sheet immediately shows the selected passage while the task starts.
4. The learner asks one or more questions in that same focused task.
5. Dismissing the sheet keeps the selection highlighted while it is unresolved.
6. Tapping the highlight reopens the same task and conversation.
7. Tapping **Resolve** archives/closes the task and removes the highlight.

## Issues

### 1. Selection chat reuses the course-generation task

- **Observed:** The Ask AI sheet shows the prompt and messages used to generate
  the entire course.
- **Cause:** The selected-text flow points `CourseChatView` at the course's
  existing `agentThreadKey`.
- **Required fix:** Create and persist a distinct task identifier for each
  selected passage. Never replace the course-generation task mapping with this
  selection task.
- **Acceptance:** A newly selected passage opens with no course-generation
  transcript. A different passage receives a different task.
- **Status:** Fixed and simulator-verified

### 2. Unresolved discussions are not represented in the document

- **Observed:** Closing Ask AI loses the visible connection between the passage
  and its discussion.
- **Required fix:** Persist a selection anchor (page, stable block ID, path,
  character range, and selected text) and render an unresolved highlight.
- **Acceptance:** Closing and reopening the page preserves the highlight.
- **Status:** Fixed and simulator-verified

### 3. Highlight does not reopen its existing discussion

- **Observed:** There is no durable way back to a passage-specific question.
- **Required fix:** Make unresolved annotations tappable and route a tap to the
  discussion's persisted task identifier.
- **Acceptance:** Tapping a highlight reopens the same transcript instead of
  creating another task.
- **Status:** Fixed and simulator-verified

### 4. Discussion has no Resolve lifecycle

- **Observed:** A learner cannot mark the passage question as finished.
- **Required fix:** Add **Resolve** to the focused chat. Resolve the local
  annotation only after the associated Codex task has been archived
  successfully.
- **Acceptance:** Resolve closes the sheet, removes the highlight, and prevents
  the resolved task from reopening through the document.
- **Status:** Fixed and simulator-verified

### 5. Chat content disappears after Send

- **Observed:** After sending a question, the sheet can become almost entirely
  blank until hydrated task items arrive.
- **Cause:** Local optimistic messages are hidden as soon as a live task object
  exists, even when that task has not produced visible conversation items yet.
- **Required fix:** Keep the selected-passage card and optimistic question
  visible through task creation and hydration. Show an explicit preparation or
  thinking state.
- **Acceptance:** From tap through response streaming, the sheet never becomes
  an unexplained blank screen.
- **Status:** Fixed and simulator-verified

### 6. Internal course-tool payloads leak into learner chat

- **Observed:** Raw MCP request/result JSON and editor page payloads appear in
  the conversation.
- **Required fix:** Filter successful/in-progress internal course tool calls
  from the learner timeline. Convert failures into short learner-facing errors.
- **Acceptance:** A successful “add explanation” action shows only the agent's
  natural-language result. No raw MCP/editor JSON is visible.
- **Status:** Fixed and simulator-verified

### 7. Streaming responses flicker or jump

- **Observed:** Streaming content can flicker because repeated updates trigger
  redundant animated scroll operations.
- **Required fix:** Coalesce follow-scroll requests and stop automatic following
  when the learner intentionally scrolls away.
- **Acceptance:** A long streaming answer remains visually stable, and manual
  scrolling is respected.
- **Status:** Fixed and simulator-verified

## Verification checklist

- [x] Focused unit tests for task routing, annotation persistence, and timeline
      projection pass.
- [x] `git diff --check` passes for all touched tracked files.
- [x] Current iOS simulator build succeeds.
- [x] Fresh build is installed into the iPhone 17 Pro simulator
      (`2ABF8F31-6E24-4308-9ED9-32CF3CAE54D3`).
- [x] Visual flow proves:
  - [x] new selection starts with a clean conversation;
  - [x] sending never blanks the sheet;
  - [x] raw course-tool payloads stay hidden;
  - [x] closing and relaunching preserves the highlight;
  - [x] tapping the highlight reopens the same conversation;
  - [x] Resolve archives the task and removes the highlight.

## Verification evidence

- `make ios-sim-fast` completed successfully.
- The final focused `xcodebuild test` run executed 75 tests with zero failures:
  `CourseExperienceStoreTests`, `CourseChatTimelinePolicyTests`,
  `WatchCompanionBridgeTests`, and `PerServerComplicationTests`.
- Simulator screenshots were captured for the clean focused discussion,
  immediate post-send state, persisted highlight after relaunch, reopened
  transcript, and cleared highlight after Resolve.
- Live logging identified a second flicker contributor: each streaming snapshot
  triggered three WidgetKit timeline reloads on the main thread. Complication
  refreshes are now coalesced into 750 ms batches using the newest snapshot.
  A post-fix streaming run remained responsive and produced only two refresh
  batches during the sampled window.

## Scope

- iOS/SwiftUI and the local NativeBlockEditor package only.
- No Android changes.
- Existing unrelated worktree changes must remain untouched.
