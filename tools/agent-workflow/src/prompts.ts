import type { AgentResult, Role, WorkflowState } from "./types.js";

const roleInstructions: Record<Role, string> = {
  lead: "Own problem framing and the acceptance contract. Do not implement. Find ambiguity, dependencies, risks, explicit non-goals, and observable success criteria.",
  productStrategist: "Challenge the proposal against the product aim and actual user journey. Reject unnecessary scope and vague UX. Do not implement.",
  engineer: "Implement the approved scope. Preserve unrelated dirty work. Make the smallest coherent change and verify it. Do not create commits, push, or open PRs.",
  testDesigner: "Design and interpret independent tests against the acceptance contract. Look for lifecycle, interruption, retry, stale state, relaunch, and regression failures.",
  testExecutor: "Execute the supplied test plan exactly. Collect command output, logs, screenshots, or other concrete evidence. Do not modify product code.",
  uxAcceptance: "Act as an independent user-perspective evaluator. Exercise the built experience when possible and judge clarity, continuity, accessibility, recovery, and product fit. Do not modify code.",
  reviewer: "Independently review the final diff for correctness, architecture, concurrency, security, regressions, and maintainability. Do not repair your own findings.",
  finalRegression: "Run the final relevant regression checks and report exact evidence. Do not modify product code.",
};

function recentContext(state: WorkflowState): string {
  const runs = state.runs.slice(-6).map((run) =>
    `${run.role} (${run.result.verdict}): ${run.result.summary}\nFindings: ${run.result.findings.join(" | ")}\nEvidence: ${run.result.evidence.join(" | ")}`,
  ).join("\n\n");
  const decisions = state.decisions.slice(-3).map((decision) =>
    `OWNER ${decision.gate} gate (${decision.decision}): ${decision.note || "No note supplied."}`,
  ).join("\n");
  return [runs, decisions].filter(Boolean).join("\n\n");
}

export function buildPrompt(role: Role, state: WorkflowState, instruction: string): string {
  return `You are the ${role} in a gated engineering workflow.\n\n${roleInstructions[role]}\n\nRepository: ${state.repository}\nOriginal task: ${state.task}\nCurrent workflow stage: ${state.stage}\n\nCurrent assignment:\n${instruction}\n\nRecent handoffs:\n${recentContext(state) || "None yet."}\n\nReturn the required structured result. Use verdict=pass only when your responsibility is satisfied with concrete evidence. Use revise for actionable work that the preceding role can address. Use blocked only for a real external or authority blocker. nextPrompt must be a concise actionable handoff. Never claim tests, UI interaction, device proof, commits, pushes, or PRs that you did not actually perform.`;
}

export function parseAgentResult(value: string): AgentResult {
  const parsed = JSON.parse(value) as AgentResult;
  if (!(["pass", "revise", "blocked"] as string[]).includes(parsed.verdict)) {
    throw new Error("Agent returned an invalid verdict");
  }
  return parsed;
}
