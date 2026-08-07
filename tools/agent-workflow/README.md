# Gated Codex workflow

This tool runs a persistent product-to-engineering workflow through local Codex SDK threads. It stops for the product owner's scope, product-acceptance, and PR decisions. Every automated feedback loop is capped at five failed rounds.

## Safety boundaries

- Normal stage transitions and counters are deterministic code. Checkpoint files are local coordination state, not a hardened security boundary against the same operating-system user.
- Only the engineer receives workspace-write access. All other roles start read-only.
- Agents run with approval policy `never` and network access disabled.
- Each role turn has a configurable timeout (10 minutes by default); interrupted workflows remain resumable from their last checkpoint.
- The orchestrator never directly commits, pushes, creates a PR, deploys, or changes production. Engineer prompts prohibit those actions, while network access is disabled; workspace-write is still a powerful local capability and should be used in a dedicated worktree for sensitive repositories.
- PR approval moves the state to `ready_for_pr`; PR creation remains a separate explicitly authorized action.
- Runtime state is stored under the target repository's ignored `.agent-workflow/runs/` directory (`0700`) with checkpoint mode `0600`.
- Dry runs and live runs are permanently distinguished in checkpoint state and cannot be resumed as the other mode.
- Live engineer turns refuse a dirty target worktree by default. Point `--repo` at a dedicated clean worktree; changing that policy requires an explicit config edit.

## Setup

```bash
cd tools/agent-workflow
npm install
npm test
npm run check
```

The SDK uses the local Codex runtime and its existing login. Confirm it first with `codex login status`.

## Run

Start with a routing-only dry run:

```bash
npm run workflow -- start --repo ../.. --task "Describe the bounded issue" --dry-run
```

Start a live workflow:

```bash
npm run workflow -- start --repo ../.. --task "Describe the bounded issue"
```

At a human gate:

```bash
npm run workflow -- decide <workflow-id> --repo ../.. --decision approve --note "Approved as scoped"
```

Use `status <workflow-id>` to inspect the checkpoint and `run <workflow-id>` to resume a non-gate stage. Include `--dry-run` every time when resuming a dry-run workflow.

## Model routing

Edit `workflow.config.json` or set `LEARNFOLD_WORKFLOW_CONFIG` to another JSON file. Each role has an ordered model candidate list. A fallback is tried only for model availability/access failures. Version 0.146.0 of the TypeScript SDK exposes up to `xhigh`; this workflow intentionally uses `high` or `medium` and does not claim unsupported `max`/`ultra` routing.

The test executor and final regression runner prefer Luna, balanced implementation and test design prefer Terra, and high-leverage product/review roles prefer Sol. Actual model access is verified by the first live role invocation.
