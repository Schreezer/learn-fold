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
- `LEARNFOLD_HOSTED_ACCESS_TOKEN` authenticates the initial private-beta client. It must not be the provider key.

Configure the iOS build/runtime with `LEARNFOLD_HOSTED_AGENT_URL` and `LEARNFOLD_HOSTED_ACCESS_TOKEN` (or the corresponding `LearnfoldHostedAgentURL` and `LearnfoldHostedAccessToken` Info.plist keys). A production release should replace the shared beta token with short-lived, user-bound tokens minted by Learnfold's authentication service.
