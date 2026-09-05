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
