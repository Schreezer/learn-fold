import { incrementLoop } from "./policy.js";
import { AgentRunner } from "./runner.js";
import { WorkflowStore } from "./store.js";
import type { AgentResult, LoopName, Role, WorkflowConfig, WorkflowState } from "./types.js";

export class WorkflowOrchestrator {
  private readonly runner: AgentRunner;

  constructor(
    private readonly config: WorkflowConfig,
    private readonly store: WorkflowStore,
    dryRun: boolean,
  ) {
    this.runner = new AgentRunner(config, dryRun);
  }

  async advance(state: WorkflowState): Promise<WorkflowState> {
    while (!isTerminalOrGate(state.stage)) {
      switch (state.stage) {
        case "discovery":
          await this.discovery(state);
          break;
        case "implementation":
          await this.implementation(state);
          break;
        case "ux_acceptance":
          await this.uxAcceptance(state);
          break;
        case "code_review":
          await this.codeReview(state);
          break;
        case "final_regression":
          await this.finalRegression(state);
          break;
        default:
          throw new Error(`Unhandled workflow stage: ${state.stage}`);
      }
      await this.store.save(state);
    }
    await this.store.save(state);
    return state;
  }

  private async discovery(state: WorkflowState): Promise<void> {
    const lead = await this.invoke("lead", state, "Produce or revise the problem definition, non-goals, risks, and observable acceptance criteria.");
    if (this.blocked(state, lead)) return;
    const product = await this.invoke("productStrategist", state, "Review the lead's definition for product fit and user journey. Pass it only when it is ready for the owner's scope decision.");
    if (this.blocked(state, product)) return;
    if (product.verdict === "pass") state.stage = "scope_gate";
    else this.repeatOrEscalate(state, "product_definition");
  }

  private async implementation(state: WorkflowState): Promise<void> {
    const design = await this.invoke("testDesigner", state, "Create or update the independent acceptance test plan before evaluating implementation evidence.");
    if (this.blocked(state, design)) return;
    const engineer = await this.invoke("engineer", state, "Implement the approved scope and address the latest test, UX, or review findings. Run focused verification.");
    if (this.blocked(state, engineer)) return;
    const execution = await this.invoke("testExecutor", state, "Execute the test designer's plan against the current implementation and record exact evidence.");
    if (this.blocked(state, execution)) return;
    const verdict = await this.invoke("testDesigner", state, "Interpret the executor evidence against every acceptance criterion. Identify actionable gaps or pass functional testing.");
    if (this.blocked(state, verdict)) return;
    if (verdict.verdict === "pass") state.stage = "ux_acceptance";
    else this.repeatOrEscalate(state, "implementation_test");
  }

  private async uxAcceptance(state: WorkflowState): Promise<void> {
    const ux = await this.invoke("uxAcceptance", state, "Independently exercise and assess the implemented user journey. Require observable evidence and pass only when product UX is acceptable.");
    if (this.blocked(state, ux)) return;
    if (ux.verdict === "pass") state.stage = "product_gate";
    else if (this.repeatOrEscalate(state, "ux_fix")) state.stage = "implementation";
  }

  private async codeReview(state: WorkflowState): Promise<void> {
    const review = await this.invoke("reviewer", state, "Independently review the current diff and verification evidence. Do not edit files. Pass only with no actionable findings.");
    if (this.blocked(state, review)) return;
    if (review.verdict === "pass") state.stage = "final_regression";
    else if (this.repeatOrEscalate(state, "code_review")) {
      const fix = await this.invoke("engineer", state, "Address the independent review findings, preserve scope, and run focused verification.");
      if (!this.blocked(state, fix)) state.stage = "code_review";
    }
  }

  private async finalRegression(state: WorkflowState): Promise<void> {
    const regression = await this.invoke("finalRegression", state, "Run the final relevant regression suite and verify that required evidence is present. Do not edit files.");
    if (this.blocked(state, regression)) return;
    if (regression.verdict === "pass") state.stage = "pr_gate";
    else if (this.repeatOrEscalate(state, "final_regression")) state.stage = "implementation";
  }

  private async invoke(role: Role, state: WorkflowState, assignment: string): Promise<AgentResult> {
    const run = await this.runner.run(role, state, assignment);
    state.runs.push(run);
    await this.store.save(state);
    return run.result;
  }

  private blocked(state: WorkflowState, result: AgentResult): boolean {
    if (result.verdict !== "blocked") return false;
    state.stage = "escalated";
    state.escalationReason = result.summary;
    return true;
  }

  private repeatOrEscalate(state: WorkflowState, loop: LoopName): boolean {
    return incrementLoop(state, loop, this.config.maxRoundsPerLoop);
  }
}

function isTerminalOrGate(stage: WorkflowState["stage"]): boolean {
  return ["scope_gate", "product_gate", "pr_gate", "ready_for_pr", "escalated", "paused", "rejected"].includes(stage);
}
