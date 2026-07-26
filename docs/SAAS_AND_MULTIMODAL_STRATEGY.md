# SaaS and Multimodal Product Strategy

Status: proposed direction, July 20, 2026

## Decision

Build one adaptive-course product with two execution modes:

1. **Personal Compute** — the learner supplies and controls the agent runtime. Today that means signing in to Codex on their iPhone, Mac, or self-hosted server. Course files and the runtime remain under the learner's control.
2. **Managed Cloud** — the learner subscribes to our service. We provide the account, synced course workspace, source storage, background media processing, managed agent runtime, notifications, and included AI usage.

These should be two modes behind the same course and asset model, not separate applications.

The paid product is not "our wrapper around somebody else's Codex subscription." The paid product is the managed learning system: durable source ingestion, adaptive curriculum state, background processing, cross-device continuity, and an agent that keeps teaching without the learner operating infrastructure.

The durable product claim remains:

> A chatbot answers your question. This app changes what it teaches you next.

## Important naming correction

Do not call the current Codex-backed mode "fully local" without qualification. Course files and execution can remain on the device or the learner's machine, but prompts and selected source content can still be sent to the model provider. Use **Personal Compute**, **Your Runtime**, or **Self-hosted** in product copy.

A genuinely offline mode would require a supported on-device or LAN-hosted open-weight model and local OCR/transcription/embedding implementations. That can be a later capability, but it is not what ChatGPT/Codex subscription authentication provides today.

## What the repository already has

The existing code is a useful foundation rather than a throwaway prototype:

- Both mobile clients share `codex-mobile-client`, which already owns session state, hydration, auth, transport, and the narrow UniFFI surface.
- Both general composers already accept images as `AppUserInput::Image`; iOS and Android expose photo, camera, and file pickers.
- Generic file attachments are currently represented mainly as a label and filesystem path. That is sufficient only when the chosen runtime can see that exact path.
- The iOS course flow copies immutable learner sources into an app-owned course workspace and mounts the course for its local agent.
- The native iOS document engine already has image and `nbe/media` primitives for video, audio, and files.
- The shared Rust layer already contains remote transports, including the Slingshot path, that can be reused for a managed runtime.
- There is StoreKit and Play Billing code for the tip jar, but there is no durable subscription entitlement system.
- The adaptive course experience is currently iOS-first. Android does not yet have equivalent course screens, so cloud/media work must avoid adding more course policy in Swift.

The central gap is that a phone-selected PDF or video does not yet have a stable identity and lifecycle across phone storage, remote runtimes, cloud object storage, derived text/transcripts, and course citations.

## The two-mode product

| Dimension | Personal Compute | Managed Cloud |
|---|---|---|
| Customer | Technical or privacy-focused learner | Learner who wants the product to simply work |
| AI account | Learner's Codex/ChatGPT sign-in or API key on their trusted runtime | Our API organization and provider accounts |
| Runtime | iPhone, Mac, PC, or learner-owned server | Isolated managed workspace/runner |
| Source storage | Local app/runtime workspace | Encrypted object storage plus local cache |
| Processing | On device/runtime where supported | Background OCR, PDF extraction, transcription, thumbnails, and indexing |
| Sync | None by default; optional export/import | Cross-device courses, progress, assets, and resumable jobs |
| Billing | Free core initially; optional separate local-pro purchase later | App Store/Play/web subscription with included usage and explicit limits |
| Main promise | Maximum control and ownership | Zero setup, continuity, background work, richer media |

### Why Managed Cloud is a real SaaS

Subscribers pay for recurring infrastructure and outcomes:

- upload once and use a source across phone, tablet, and web;
- turn PDFs, videos, images, audio, and links into cited course material;
- let long-running extraction and course-generation jobs finish in the background;
- keep the learner model, curriculum graph, notes, progress, and generated pages synchronized;
- receive notifications when a course or chapter is ready;
- avoid installing Codex, maintaining SSH, or operating a server;
- get predictable support, quotas, retention, deletion, and recovery.

This recurring value fits a SaaS subscription better than charging merely for access to a chat box.

## OpenAI account boundary

Keep the following invariant:

- Personal Compute may use a learner's own ChatGPT/Codex login only on the learner's trusted local or self-hosted runtime.
- Managed Cloud must not pool, proxy, or resell a consumer ChatGPT login. It should use our API account through a server-side provider gateway, with per-user usage accounting.
- Never ask users to paste `auth.json`, browser session credentials, or reusable ChatGPT tokens into our backend.
- A future enterprise deployment can support organization-managed Codex access tokens only for trusted workflows owned by that organization; it is not the default consumer SaaS path.

OpenAI's current business terms allow integrating the API into a customer application for end users, while prohibiting shared login credentials, reselling account access, and buying/selling/transferring API keys. The Codex authentication documentation also distinguishes ChatGPT subscription access from API-key usage and warns against exposing Codex execution in untrusted or public environments.

This is product architecture guidance, not a substitute for legal review before launch.

## Canonical asset architecture

### 1. Put the cross-platform asset contract in Rust

Add a small, handwritten UniFFI-safe asset surface in `codex-mobile-client`:

```text
AssetRecord
  id: AssetId
  workspace_id: WorkspaceId
  display_name: String
  kind: image | pdf | video | audio | document | archive | other
  mime_type: String
  byte_size: u64
  sha256: String
  origin: camera | photo_library | file_picker | url | generated
  availability: local | uploading | cloud | mounted | unavailable
  processing: pending | processing | ready | failed
  local_ref?: opaque platform bookmark/key
  remote_ref?: opaque object identifier
  runtime_path?: String
  derived_artifacts: [DerivedAsset]
```

`DerivedAsset` should cover extracted text, page images, thumbnails, transcript segments, OCR text, captions, and metadata. It must preserve source coordinates such as page number or video time range so the course can cite and reopen the exact evidence.

Platform code should own pickers, permissions, security-scoped bookmarks, playback, and native rendering. Rust should own hashing, dedupe, state transitions, upload coordination, processing status normalization, and how assets become course context.

Direct asset operations belong on `AppClient`. Canonical asset snapshots and updates belong in `AppStore`. Do not add a parallel Swift or Kotlin asset state machine.

### 2. Do not send large files as base64 JSON-RPC input

The existing image data URI is acceptable for bounded images, after compression and size limits. It is the wrong transport for PDFs and videos.

Use this flow:

1. The platform picker returns a local file handle.
2. The client validates declared MIME, magic bytes, and size.
3. Rust computes the digest and creates an `AssetRecord`.
4. Personal Compute copies or streams the asset into the selected runtime workspace.
5. Managed Cloud requests a short-lived upload URL, uploads directly to object storage, and finalizes the asset.
6. The runtime receives an asset ID or mounted path, never a phone-only path.
7. Processing emits typed progress updates into the Rust store.

Uploads must be resumable for video, idempotent by asset/digest, and isolated by tenant/workspace.

### 3. Normalize every source before the course agent uses it

| Source | Ingestion | Derived course context | Reader experience |
|---|---|---|---|
| Image | Decode, normalize orientation, bound resolution | OCR, caption, visual analysis, thumbnail | Zoomable image with source metadata |
| PDF | Validate, extract text per page, render page thumbnails | Page-numbered chunks, tables/images where possible | PDFKit/Android PDF viewer plus deep links to cited page |
| Video | Probe metadata, extract audio and representative frames | Time-coded transcript, chapter/scene boundaries, key frames | Native player with seek-to-citation |
| Audio | Probe and transcribe | Time-coded transcript and speaker labels where available | Native player with seek-to-citation |
| Document | Type-specific extraction, safe fallback | Section-aware text and metadata | Native preview or external open |
| URL | Fetch under SSRF/content limits, snapshot metadata | Clean article text and canonical URL | Link preview plus stored citation |

For the first release, accept common, bounded types rather than `.data` without product-level limits. A sensible initial allowlist is JPEG/PNG/WebP/HEIC, PDF, MP4/MOV, MP3/M4A/WAV, Markdown, plain text, DOCX, and PPTX. Each type needs a declared maximum size and a clear error before upload.

### 4. Render typed blocks, not arbitrary HTML

Keep the native document tree as the course source of truth:

- image block;
- video block;
- audio block;
- PDF/reference block;
- citation block with asset ID plus page/time locator;
- file/download block;
- isolated, sanitized HTML only when a typed native block is insufficient.

iOS can build on the existing `DocumentImageBlockView` and `NativeMediaBlockView`, then add a PDFKit-backed block. Android should project the same Rust/JSON document types with Coil, Media3, and a native PDF surface. The agent should write asset IDs and locators, not raw device paths.

## Managed Cloud architecture

### Control plane

- account and device identity;
- workspace membership and tenant isolation;
- subscription entitlement and usage ledger;
- asset metadata and signed upload/download URLs;
- course/job orchestration;
- notification routing;
- deletion/export and retention controls.

### Data plane

- object storage for original and derived assets;
- queue-backed media workers;
- isolated per-workspace agent runners;
- provider gateway for OpenAI and future providers;
- Slingshot-compatible streaming transport back to the mobile client;
- encrypted database for course graph, progress, citations, and job state.

### Required safety properties

- never mount one tenant's objects into another tenant's runner;
- short-lived signed URLs and scoped service credentials;
- MIME/magic-byte validation, malware scanning, decompression limits, and archive-bomb protection;
- explicit source/file size, processing-minute, model-usage, and concurrency quotas;
- idempotency keys for upload finalization and job creation;
- auditable asset deletion that removes originals, derivatives, embeddings, and runner caches;
- no provider credential returned to a mobile client;
- provider cost and rate-limit circuit breakers per user and globally.

## Subscription design

Start with two visible choices, not a complicated pricing matrix:

### Personal Compute — Free

- connect your own Codex/runtime;
- local course library and progress;
- local source import;
- image input and bounded local PDF/document support;
- manual export/import;
- no managed storage or guaranteed background jobs.

The free mode is the acquisition and trust engine. It also preserves the product's current open, user-owned identity.

### Managed Cloud — paid monthly/annual

- no Codex setup required;
- synced course library and progress;
- managed source storage;
- PDF/image processing;
- video/audio transcription allowance;
- background course generation and notifications;
- included AI usage with transparent monthly limits;
- priority/reliable processing and recovery.

Do not launch "unlimited AI." Package an included monthly allowance and expose remaining usage before the user starts an expensive job. Later, add top-ups or a higher plan only after real cost distributions are known.

A reasonable beta hypothesis is a single paid plan around the normal prosumer productivity price band, with annual discounting. Final price and included media/model allowances should come from measured cost per activated learner, not guesswork in this document.

### Billing implementation

- Use StoreKit 2 auto-renewable subscriptions on iOS and Play Billing subscriptions on Android for purchases offered inside the apps.
- Add a backend entitlement ledger that verifies signed store transactions/purchase tokens. A client-side `isPremium` boolean is not authoritative.
- Use one internal entitlement such as `managed_cloud_v1`, regardless of whether it was purchased from Apple, Google, or the web.
- Preserve access through grace period/account hold states and expose a restore/manage-subscription path.
- If web billing is added, reconcile it into the same entitlement ledger and follow current store rules for links and calls to action by storefront/region.
- Do not repurpose the existing non-consumable tip-jar products as subscription authority.

Apple currently recognizes SaaS/cloud support as valid ongoing subscription value and requires subscription benefits across a user's devices. Google Play generally requires Play Billing for in-app digital subscriptions and cloud services, with region/program-specific alternatives.

## Recommended delivery sequence

### Phase 0 — Freeze the contracts

Before backend work, write and approve:

- the two-mode product promise;
- `AssetRecord`, `DerivedAsset`, and citation locator schemas;
- local/cloud availability state machine;
- initial supported types and per-type limits;
- privacy/retention defaults;
- the single paid entitlement and usage-meter vocabulary.

Exit condition: iOS, Android, Rust, and backend names agree before bindings or APIs are generated.

### Phase 1 — Local multimodal foundation

Implement the shared Rust asset model and local asset registry first. Replace generic path-only composer attachments with asset-backed references. Ship:

- multiple image attachments;
- PDF import, extraction, page citations, and native viewing;
- video/audio import with metadata and native playback;
- typed processing/error states;
- iOS and Android composer parity;
- course-agent asset tools that resolve an asset ID into a runtime-readable path.

Video transcription can initially require the managed cloud or a capable user-owned runtime; local import/playback should not imply local transcription.

Exit condition: the same course/source manifest can move between execution modes without rewriting course content.

### Phase 2 — Thin cloud vertical slice

Build only one end-to-end hosted workflow:

1. create account;
2. obtain entitlement;
3. create a managed workspace;
4. upload one PDF or image through a signed URL;
5. process it;
6. start a managed course-agent turn;
7. stream progress/result through the existing Rust client transport;
8. reopen the course on another device;
9. delete/export the workspace.

Avoid video in the first cloud slice. PDF plus image proves storage, processing, citations, tenancy, billing, and sync at lower cost and operational risk.

### Phase 3 — Paid beta

- StoreKit/Play subscription purchase and restore;
- server-verified entitlement ledger;
- usage dashboard and hard cost ceilings;
- background notifications;
- support/admin tooling for failed jobs, refunds, deletion, and quota overrides;
- privacy policy and store-review notes that explain both modes clearly.

Exit condition: a subscriber can pay, upload, generate, learn, cancel, restore, export, and delete without manual database intervention.

### Phase 4 — Video and richer adaptation

- resumable multipart video upload;
- transcription and scene/key-frame pipeline;
- time-coded citations and seek-to-source;
- adaptive quizzes tied to specific evidence;
- course revision based on learner confusion and performance;
- higher plan/top-ups only after unit economics are understood.

## What to build next

The immediate engineering slice should be **Asset Foundation RFC + local PDF vertical slice**, not the billing backend.

Concrete first pull request boundaries:

1. Add handwritten Rust `AssetId`, `AssetKind`, `AssetAvailability`, `AssetProcessingState`, `AssetRecord`, and `AssetCitationLocator` types.
2. Add a local asset manifest/store with digest dedupe and tests.
3. Add `AppClient` import/resolve operations and `AppStore` asset snapshots/updates only where live state is needed.
4. Regenerate Swift/Kotlin bindings.
5. Change iOS and Android composers to keep an asset ID instead of treating a picker URL/path as the durable identity.
6. Add PDF as the first non-image asset: bounded import, extraction adapter, native preview, and page locator.
7. Keep current image input working through a compatibility adapter while migrating it to the asset model.
8. Update Android parity QA and add Rust reducer/manifest tests plus platform picker/render tests.

This slice creates the seam the SaaS backend will use later and improves the current local product immediately.

## Decisions deliberately deferred

- exact cloud price and included token/media allowances;
- provider/model routing and whether non-OpenAI providers are launch requirements;
- web app scope;
- team/classroom collaboration;
- public course marketplace or creator monetization;
- end-to-end encrypted cloud processing, which conflicts with ordinary server-side extraction unless designed around client-held keys and trusted execution;
- true offline local models.

## Success metrics

Measure product value separately from model usage:

- percentage of new learners who create a course;
- source import success by media type;
- time from source upload to first useful lesson;
- percentage of generated lessons with reopenable source citations;
- week-one course continuation;
- number of course revisions caused by learner behavior/questions;
- cloud gross margin by active learner;
- processing failure and manual-support rate;
- conversion from Personal Compute to Managed Cloud;
- cloud cancellation reasons.

## Primary risks

1. **Calling it local when content leaves the device.** Fix with precise mode copy and per-source disclosure.
2. **Building two products.** Fix with one Rust asset/course model and two execution/storage adapters.
3. **Cloud costs outrunning subscription revenue.** Fix with measured allowances, quotas, and no unlimited launch plan.
4. **Large media becoming a reliability problem.** Fix with direct/resumable uploads, asynchronous jobs, and typed progress.
5. **Path references that only work on the originating device.** Fix with asset IDs plus runtime/cloud resolution.
6. **iOS-only course policy growing further.** Fix by moving asset, processing, citation, and course-runtime state into Rust before cloud work.
7. **Credential or tenant leakage.** Fix with user-owned credentials only on trusted personal runtimes and isolated provider-backed runners for SaaS.
8. **Store rejection or broken entitlement state.** Fix with native billing, server verification, restore/cancel support, and explicit review notes.

## Current official references

- [OpenAI Codex authentication](https://learn.chatgpt.com/docs/auth)
- [OpenAI Services Agreement](https://openai.com/policies/services-agreement/)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Google Play Payments policy](https://support.google.com/googleplay/android-developer/answer/9858738)
- [Google Play subscription requirements](https://support.google.com/googleplay/android-developer/answer/9900533)
