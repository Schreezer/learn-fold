import type { ModelReasoningEffort, SandboxMode } from "@openai/codex-sdk";

export const roles = [
  "lead",
  "productStrategist",
  "engineer",
  "testDesigner",
  "testExecutor",
  "uxAcceptance",
  "reviewer",
  "finalRegression",
] as const;

export type Role = (typeof roles)[number];

export const stages = [
  "discovery",
  "scope_gate",
  "implementation",
  "ux_acceptance",
  "product_gate",
  "code_review",
  "final_regression",
  "pr_gate",
  "ready_for_pr",
  "escalated",
  "paused",
  "rejected",
] as const;

export type Stage = (typeof stages)[number];
export type LoopName = "product_definition" | "implementation_test" | "ux_fix" | "code_review" | "final_regression";
export type HumanGate = "scope" | "product" | "pr";
export type Verdict = "pass" | "revise" | "blocked";

export interface RoleModelConfig {
  candidates: string[];
  reasoningEffort: ModelReasoningEffort;
}

export interface WorkflowConfig {
  version: 1;
  maxRoundsPerLoop: number;
  turnTimeoutMs: number;
  requireCleanWorktreeForEngineer: boolean;
  models: Record<Role, RoleModelConfig>;
}

export interface AgentResult {
  verdict: Verdict;
  summary: string;
  findings: string[];
  evidence: string[];
  nextPrompt: string;
}

export interface RoleRun {
  role: Role;
  model: string;
  reasoningEffort: ModelReasoningEffort;
  sandboxMode: SandboxMode;
  startedAt: string;
  completedAt: string;
  result: AgentResult;
}

export interface HumanDecision {
  gate: HumanGate;
  decision: "approve" | "revise" | "pause" | "reject";
  note: string;
  decidedAt: string;
}

export interface WorkflowState {
  version: 1;
  executionMode: "live" | "dry-run";
  id: string;
  task: string;
  repository: string;
  stage: Stage;
  createdAt: string;
  updatedAt: string;
  loopCounts: Record<LoopName, number>;
  threads: Partial<Record<Role, string>>;
  runs: RoleRun[];
  decisions: HumanDecision[];
  escalationReason: string | null;
}
