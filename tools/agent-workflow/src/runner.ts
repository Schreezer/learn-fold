import { Codex, type SandboxMode, type Thread } from "@openai/codex-sdk";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { agentResultSchema } from "./schema.js";
import { buildPrompt, parseAgentResult } from "./prompts.js";
import type { AgentResult, Role, RoleRun, WorkflowConfig, WorkflowState } from "./types.js";

const readOnlyRoles = new Set<Role>([
  "lead",
  "productStrategist",
  "testDesigner",
  "testExecutor",
  "uxAcceptance",
  "reviewer",
  "finalRegression",
]);
const execFileAsync = promisify(execFile);

function unavailableModel(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /unknown model|unsupported model|model[^\n]*(?:not found|does not exist|unavailable|not available)|(?:access|permission)[^\n]*model/i.test(message);
}

export class AgentRunner {
  private readonly codex = new Codex();

  constructor(
    private readonly config: WorkflowConfig,
    private readonly dryRun: boolean,
  ) {}

  async run(role: Role, state: WorkflowState, assignment: string): Promise<RoleRun> {
    const roleConfig = this.config.models[role];
    const sandboxMode: SandboxMode = readOnlyRoles.has(role) ? "read-only" : "workspace-write";
    const startedAt = new Date().toISOString();

    if (!this.dryRun && role === "engineer" && this.config.requireCleanWorktreeForEngineer) {
      const { stdout } = await execFileAsync("git", ["status", "--porcelain"], { cwd: state.repository });
      if (stdout.trim()) {
        throw new Error("Engineer refused: target worktree is dirty. Use a dedicated clean worktree or explicitly change the reviewed workflow policy.");
      }
    }

    if (this.dryRun) {
      return {
        role,
        model: roleConfig.candidates[0]!,
        reasoningEffort: roleConfig.reasoningEffort,
        sandboxMode,
        startedAt,
        completedAt: new Date().toISOString(),
        result: dryResult(role),
      };
    }

    let lastError: unknown;
    const previousModel = [...state.runs].reverse().find((run) => run.role === role)?.model;
    const candidates = previousModel
      ? [previousModel, ...roleConfig.candidates.filter((model) => model !== previousModel)]
      : roleConfig.candidates;
    for (const model of candidates) {
      try {
        const thread = this.threadFor(role, model, sandboxMode, state);
        const signal = AbortSignal.timeout(this.config.turnTimeoutMs);
        const turn = await thread.run(buildPrompt(role, state, assignment), {
          outputSchema: agentResultSchema,
          signal,
        });
        if (thread.id) state.threads[role] = thread.id;
        return {
          role,
          model,
          reasoningEffort: roleConfig.reasoningEffort,
          sandboxMode,
          startedAt,
          completedAt: new Date().toISOString(),
          result: parseAgentResult(turn.finalResponse),
        };
      } catch (error) {
        lastError = error;
        if (!unavailableModel(error)) throw error;
      }
    }
    throw lastError instanceof Error ? lastError : new Error(String(lastError));
  }

  private threadFor(role: Role, model: string, sandboxMode: SandboxMode, state: WorkflowState): Thread {
    const options = {
      model,
      modelReasoningEffort: this.config.models[role].reasoningEffort,
      sandboxMode,
      workingDirectory: state.repository,
      approvalPolicy: "never" as const,
      networkAccessEnabled: false,
    };
    const existing = state.threads[role];
    return existing ? this.codex.resumeThread(existing, options) : this.codex.startThread(options);
  }
}

function dryResult(role: Role): AgentResult {
  return {
    verdict: "pass",
    summary: `Dry-run ${role} completed`,
    findings: [],
    evidence: ["Synthetic dry-run evidence; no agent or command was executed."],
    nextPrompt: "Continue to the next workflow responsibility.",
  };
}
