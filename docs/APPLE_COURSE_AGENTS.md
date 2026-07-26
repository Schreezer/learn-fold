# Apple course agents

Learnfold supports three provider identities for course conversations:

- `codex`
- `apple-on-device`
- `apple-private-cloud`

Private Cloud Compute is the preferred setup default when it is available.
Apple On-Device is the fallback Apple choice. Codex remains enabled when Apple
Intelligence is unsupported, disabled, not ready, or unavailable.

## Conversation ownership

A conversation belongs to the provider family that created it:

- Codex conversations always remain Codex conversations.
- Apple conversations can switch between On-Device and Private Cloud Compute.
- Switching an Apple conversation preserves its visible messages and Learnfold
  course workspace, then rebases the model's working transcript through a
  durable summary so the target model never inherits stale tool definitions.

The selection-discussion flow follows the same rule. Every highlighted passage
gets its own persisted session. Resolving the discussion removes that Apple
session and allows the highlight to close.

## Tool execution

Apple models use Foundation Models `Tool` values and call
`CourseDocumentRegistry` directly. They do not use the Codex loopback MCP
server. The native repository remains the authoritative document boundary and
retains revision checks.

Every Apple-presented plan is persisted as `.course/presented-plan.json`.
Editor mutations require `.course/approved-plan.json` to have the same
non-empty plan ID and revision, preventing an older approval from authorizing a
newer proposal. On-Device receives one compact, phase-aware course action tool.
Plan fields are flattened into that tool's root schema, with scalar fields
ordered before the chapter array; native-editor actions use a compact JSON
argument string. This avoids the on-device model serializing nested schema
fragments into plan fields while conserving its smaller context window. A
malformed model call is returned to the model as a correctable tool result
instead of surfacing a framework decoding error to the learner. Generated plans
are validated before they reach the approval UI. Private Cloud Compute receives
the full typed plan and native-editor schemas.

## Context compaction

Visible chat history stays intact, but the model's working transcript compacts
before the provider limit:

- The policy ceiling is 6,500 tokens for Apple On-Device, but Learnfold also
  reads the model's actual context size and reserves 1,500 tokens for the
  summary plus 512 tokens for instructions. Apple's current 4,096-token
  on-device model therefore compacts at 2,084 tokens.
- Private Cloud Compute compacts at 27,500 tokens within its 32,768-token
  context window.
- Both summaries are capped at 1,500 generated tokens.

On iOS 26.4 and later, On-Device uses Apple's exact transcript and prompt token
counts. The fallback estimate conservatively uses UTF-8 size, word-piece
counts, and non-ASCII scalar counts, and includes the incoming learner prompt.
Compaction preserves learner goals, starting knowledge, preferences, unresolved
questions, source links, exact workspace/page/tool IDs, revisions, tool
results, and presented/approved plan state. The summary and replacement
transcript are persisted in the course's `.course` metadata so relaunching does
not restore the oversized context.

Every On-Device/Private Cloud Compute switch compacts with the source provider,
then starts the target session from that durable summary. In particular,
Private Cloud Compute compacts its potentially larger transcript before an
On-Device session begins. If PCC is unavailable, offline, or quota-limited
during that fallback, Learnfold builds a bounded local transition summary from
the authoritative persisted plan state, the previous durable summary, and the
newest transcript context. Switching back to On-Device therefore does not
depend on one final successful PCC request. In the other direction, if the
on-device model becomes unavailable during the switch, the already-validated
PCC target summarizes the smaller local transcript and takes over.

If the framework reports a context overflow despite preflight counting,
Learnfold retries only when the session transcript proves no tool call or
partial output occurred. A turn that might already have mutated the course is
never replayed. A first turn has nothing to compact, so Learnfold counts its
instructions, tool schema, and learner prompt up front and asks the learner to
shorten an oversized request or begin with PCC instead of exposing a framework
overflow error.

## Private Cloud Compute release requirement

Private Cloud Compute requires all of the following:

1. Xcode and the iOS 27 SDK.
2. An iOS 27 device eligible for Apple Intelligence.
3. Apple granting the managed
   `com.apple.developer.private-cloud-compute` entitlement.
4. The entitlement being present in the app's distribution provisioning
   profile.

The entitlement is enabled in `apps/ios/project.yml` after Apple granted the
managed capability to the owned App ID. Any development or distribution
profile created before that grant must be regenerated; a stale profile will
still fail archive signing.

Learnfold's owned Apple identity family is:

- Main iOS and Mac Catalyst app: `com.chirag.learnfold`
- Live Activity extension: `com.chirag.learnfold.liveactivity`
- Watch app: `com.chirag.learnfold.watchkitapp`
- Watch complication extension:
  `com.chirag.learnfold.watchkitapp.complications`
- App Group: `group.com.chirag.learnfold`

PCC is granted and enabled on the main `com.chirag.learnfold` App ID. Regenerate
its development and distribution provisioning profiles and confirm the
embedded profile contains `com.apple.developer.private-cloud-compute`.

CarPlay Voice Based Conversation is a separate managed capability and is not
currently granted to the new App ID. Its signing entitlement stays disabled
until Apple grants it; the CarPlay source remains in the project.

The iOS 27 symbols are gated by the
`LEARNFOLD_PRIVATE_CLOUD_COMPUTE_SDK` compilation condition, which XcodeGen
adds only for iOS 27 device and simulator SDKs. This keeps the project building
with the current iOS 26 SDK without incorrectly depending on the Swift language
version. A release containing PCC must be compiled and tested again with Xcode
27 before distribution.

## Deterministic testing

Debug and test launches can override capability detection:

- `SNAPPY_APPLE_ON_DEVICE_AVAILABLE=1|0`
- `SNAPPY_APPLE_PRIVATE_CLOUD_AVAILABLE=1|0`

These switches exercise setup defaults and unavailable-device UI. They do not
replace real-device inference, quota, network, entitlement, or privacy
verification.
