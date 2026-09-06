# Learnfold Hosted Agent

Cloudflare Worker + Durable Object runtime for Learnfold course conversations. It uses Cloudflare Think for server-authoritative transcripts, stream recovery, tool-result continuation, and automatic compaction. The model adapter targets `deepseek-v4-flash` through OpenCode Zen Go's OpenAI-compatible Chat Completions endpoint.

Pi is intentionally not part of this service. Think owns the durable agent loop, while the iOS app executes the allowlisted native course tools and returns their results to the same durable session.

## Local verification

```sh
npm install
npm run types
npm run check
npm test
```

Copy `.dev.vars.example` to `.dev.vars` only for local development. Never commit either secret.

## Deployment

Create two independent secrets:

```sh
npx wrangler secret put OPENCODE_API_KEY
npx wrangler secret put LEARNFOLD_HOSTED_ACCESS_TOKEN
npm run deploy
```

- `OPENCODE_API_KEY` exists only inside the Worker and is sent only to OpenCode.
- `LEARNFOLD_HOSTED_ACCESS_TOKEN` authenticates existing private-beta clients and signs guest session tokens. It must not be the provider key and is never bundled with guest builds.

Configure the iOS build with `LEARNFOLD_HOSTED_AGENT_URL`. No login or access token is required for the beta. The iOS Keychain retains a random 256-bit installation secret, scoped to the service URL. Rust exchanges it at `POST /guest-session?sessionId=<uuid>` using the `Guest` authorization scheme. The returned one-hour bearer token is bound to that guest and conversation. The Worker routes it into a separate guest namespace, preserving history across reconnects without allowing access to another guest's conversation or the legacy shared-token namespace.

Guest access supports only chat WebSocket upgrades. Durable counters allow 120 token exchanges per IP per UTC day, 60 agent turns per guest per day, and 1,000 guest turns globally per day. Think continuations also consume the turn budget. Each guest turn allows at most 12 model steps and 8,192 output tokens per step. These are beta usage limits, not a currency-denominated spending cap. Set `GUEST_BETA_ENABLED` to `"false"` to disable guest bootstrap and further guest turns. Existing shared-token clients remain supported.

`LEARNFOLD_HOSTED_ACCESS_TOKEN` and the corresponding `LearnfoldHostedAccessToken` Info.plist key remain optional runtime overrides for existing private tests. An explicitly empty environment override clears the bundled value. Never put a real shared token in a shipped build. Guest identity is device-local; account-based sync and guest-to-account migration are separate features.

## Diagnosing slow replies

Workers Logs are enabled at a sampling rate of 1. Filter for `component = learnfold.hosted`, or capture a live session with `npx wrangler tail --format json`. Cloudflare may deliver invocation logs together after the invocation completes; tail output is not a continuously queryable in-flight status endpoint.

Correlate the opaque Durable Object `sessionID`, chat `requestID`, and per-provider-call `providerCallID`. The structured records include:

- `chat:turn:start`, `turn.prepared`, `chat:turn:finish`: admission, preparation and completion. Continuations are marked separately.
- `provider.request`, `provider.headers`, `provider.first_byte`: outbound request, HTTP status and first response bytes. `elapsedMs` measures from the provider request.
- `provider.first_reasoning`, `provider.first_text`, `provider.first_tool`: first non-empty reasoning, answer text or tool data in the raw provider SSE stream. Only milestone types are recorded, never content. A long gap between reasoning and text identifies hidden model deliberation; a long wait for headers points earlier in the provider path.
- `model.tool-call` and a subsequent continuation: model handoff to native tools and resumed inference. A handoff without continuation warrants checking the phone connection/tool execution.
- `chat:stream:stalled`, `chat:recovery:*`, `chat:request:failed`, and provider transport/stream errors: watchdog, retry and failure events. HTTP status distinguishes rate limiting from other provider failures.
- `provider.usage`: final numeric token usage when supplied by the provider. Providers may send cumulative usage on every token; these updates are aggregated into one record per HTTP stream.

Learner text, reasoning text, tool names/arguments/results, request URLs, credentials and raw error messages are excluded from this telemetry. SSE inspection buffers at most 64 KiB per line and forwards the original bytes with backpressure and cancellation intact. These records apply only to traffic after the telemetry deployment; they cannot reconstruct earlier uninstrumented requests.

Focused selected-passage questions use `reasoningEffort: low`, including their tool continuations. The phone's existing selected-passage prompt envelope identifies this path. Course planning and approved lesson generation retain the provider defaults. Reasoning remains enabled; lowering effort is a latency tradeoff, not a guarantee of a response deadline.
