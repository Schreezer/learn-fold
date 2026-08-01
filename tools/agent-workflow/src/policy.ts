import type { HumanDecision, HumanGate, LoopName, Stage, WorkflowState } from "./types.js";

export const gateForStage: Partial<Record<Stage, HumanGate>> = {
  scope_gate: "scope",
  product_gate: "product",
  pr_gate: "pr",
};

export function incrementLoop(state: WorkflowState, loop: LoopName, limit: number): boolean {
  state.loopCounts[loop] += 1;
  if (state.loopCounts[loop] >= limit) {
    state.stage = "escalated";
    state.escalationReason = `${loop} reached its ${limit}-round limit`;
    return false;
  }
  return true;
}

export function applyHumanDecision(state: WorkflowState, decision: HumanDecision, loopLimit = 5): void {
  const expected = gateForStage[state.stage];
  if (expected !== decision.gate) {
    throw new Error(`Workflow is at ${state.stage}; expected ${expected ?? "no"} gate, not ${decision.gate}`);
  }
  state.decisions.push(decision);
  if (decision.decision === "pause") {
    // Stay at the same gate so the owner can resume with a later decision.
    return;
  }
  if (decision.decision === "reject") {
    state.stage = "rejected";
    return;
  }
  if (decision.gate === "scope") {
    if (decision.decision === "approve") state.stage = "implementation";
    else if (incrementLoop(state, "product_definition", loopLimit)) state.stage = "discovery";
  } else if (decision.gate === "product") {
    if (decision.decision === "approve") state.stage = "code_review";
    else if (incrementLoop(state, "ux_fix", loopLimit)) state.stage = "implementation";
  } else {
    if (decision.decision === "approve") state.stage = "ready_for_pr";
    else if (incrementLoop(state, "code_review", loopLimit)) state.stage = "implementation";
  }
}
