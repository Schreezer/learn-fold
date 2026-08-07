#!/usr/bin/env node
import { randomUUID } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig } from "./config.js";
import { WorkflowOrchestrator } from "./orchestrator.js";
import { applyHumanDecision, gateForStage } from "./policy.js";
import { WorkflowStore } from "./store.js";
import type { HumanDecision, HumanGate, WorkflowState } from "./types.js";

const toolRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

async function main(): Promise<void> {
  const [command, ...args] = process.argv.slice(2);
  const repository = path.resolve(option(args, "--repo") ?? process.cwd());
  const store = new WorkflowStore(repository);
  const config = await loadConfig(toolRoot);

  if (command === "start") {
    const task = option(args, "--task");
    if (!task) throw new Error("start requires --task <description>");
    const state = newState(task, repository, flag(args, "--dry-run"));
    await store.save(state);
    await runAndPrint(state, store, config, flag(args, "--dry-run"));
    return;
  }
  if (command === "run") {
    const id = positional(args);
    if (!id) throw new Error("run requires <workflow-id>");
    await runAndPrint(await store.load(id), store, config, flag(args, "--dry-run"));
    return;
  }
  if (command === "status") {
    const id = positional(args);
    if (!id) throw new Error("status requires <workflow-id>");
    printState(await store.load(id));
    return;
  }
  if (command === "decide") {
    const id = positional(args);
    const decisionValue = option(args, "--decision") as HumanDecision["decision"] | undefined;
    if (!id || !decisionValue || !["approve", "revise", "pause", "reject"].includes(decisionValue)) {
      throw new Error("decide requires <workflow-id> --decision approve|revise|pause|reject [--note <text>]");
    }
    const state = await store.load(id);
    const gate = gateForStage[state.stage];
    if (!gate) throw new Error(`Workflow ${id} is not waiting at a human gate`);
    applyHumanDecision(state, {
      gate,
      decision: decisionValue,
      note: option(args, "--note") ?? "",
      decidedAt: new Date().toISOString(),
    }, config.maxRoundsPerLoop);
    await store.save(state);
    if (decisionValue === "approve" || decisionValue === "revise") {
      await runAndPrint(state, store, config, flag(args, "--dry-run"));
    } else {
      printState(state);
    }
    return;
  }
  usage();
  process.exitCode = command ? 1 : 0;
}

function newState(task: string, repository: string, dryRun: boolean): WorkflowState {
  const now = new Date().toISOString();
  return {
    version: 1,
    executionMode: dryRun ? "dry-run" : "live",
    id: randomUUID().slice(0, 12),
    task,
    repository,
    stage: "discovery",
    createdAt: now,
    updatedAt: now,
    loopCounts: { product_definition: 0, implementation_test: 0, ux_fix: 0, code_review: 0, final_regression: 0 },
    threads: {},
    runs: [],
    decisions: [],
    escalationReason: null,
  };
}

async function runAndPrint(state: WorkflowState, store: WorkflowStore, config: Awaited<ReturnType<typeof loadConfig>>, dryRun: boolean): Promise<void> {
  const requestedMode = dryRun ? "dry-run" : "live";
  if (state.executionMode !== requestedMode) {
    throw new Error(`Workflow ${state.id} is ${state.executionMode}; refusing to resume it as ${requestedMode}`);
  }
  const orchestrator = new WorkflowOrchestrator(config, store, dryRun);
  printState(await orchestrator.advance(state));
}

function printState(state: WorkflowState): void {
  const gate = gateForStage[state.stage];
  console.log(JSON.stringify({
    id: state.id,
    stage: state.stage,
    executionMode: state.executionMode,
    waitingForYou: gate ?? null,
    loopCounts: state.loopCounts,
    runs: state.runs.length,
    escalationReason: state.escalationReason,
    stateFile: path.join(state.repository, ".agent-workflow", "runs", `${state.id}.json`),
  }, null, 2));
  if (gate) console.log(`\nYour decision: npm run workflow -- decide ${state.id} --repo "${state.repository}" --decision approve|revise|pause|reject --note "..."`);
}

function option(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

function flag(args: string[], name: string): boolean {
  return args.includes(name);
}

function positional(args: string[]): string | undefined {
  return args.find((arg, index) => !arg.startsWith("--") && (index === 0 || !args[index - 1]?.startsWith("--")));
}

function usage(): void {
  console.log(`Learnfold gated agent workflow\n\nCommands:\n  start --task <description> [--repo <path>] [--dry-run]\n  run <workflow-id> [--repo <path>] [--dry-run]\n  status <workflow-id> [--repo <path>]\n  decide <workflow-id> --decision approve|revise|pause|reject [--note <text>] [--dry-run]`);
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
