import assert from "node:assert/strict";
import test from "node:test";
import { applyHumanDecision, incrementLoop } from "../src/policy.js";
import type { WorkflowState } from "../src/types.js";

function state(stage: WorkflowState["stage"] = "discovery"): WorkflowState {
  return {
    version: 1,
    executionMode: "dry-run",
    id: "test-run",
    task: "test",
    repository: "/tmp/test",
    stage,
    createdAt: "2026-08-01T00:00:00Z",
    updatedAt: "2026-08-01T00:00:00Z",
    loopCounts: { product_definition: 0, implementation_test: 0, ux_fix: 0, code_review: 0, final_regression: 0 },
    threads: {}, runs: [], decisions: [], escalationReason: null,
  };
}

test("a loop escalates exactly at the fifth failed round", () => {
  const value = state();
  for (let round = 1; round < 5; round += 1) {
    assert.equal(incrementLoop(value, "implementation_test", 5), true);
    assert.notEqual(value.stage, "escalated");
  }
  assert.equal(incrementLoop(value, "implementation_test", 5), false);
  assert.equal(value.stage, "escalated");
  assert.match(value.escalationReason ?? "", /5-round limit/);
});

test("scope approval advances to implementation", () => {
  const value = state("scope_gate");
  applyHumanDecision(value, { gate: "scope", decision: "approve", note: "go", decidedAt: "now" });
  assert.equal(value.stage, "implementation");
});

test("a decision at the wrong gate is rejected", () => {
  const value = state("product_gate");
  assert.throws(() => applyHumanDecision(value, { gate: "scope", decision: "approve", note: "", decidedAt: "now" }), /expected product/);
});

test("PR approval prepares but does not create a PR", () => {
  const value = state("pr_gate");
  applyHumanDecision(value, { gate: "pr", decision: "approve", note: "", decidedAt: "now" });
  assert.equal(value.stage, "ready_for_pr");
});

test("pause remains resumable at the current owner gate", () => {
  const value = state("scope_gate");
  applyHumanDecision(value, { gate: "scope", decision: "pause", note: "later", decidedAt: "now" });
  assert.equal(value.stage, "scope_gate");
});

test("owner-requested revisions share the five-round loop ceiling", () => {
  const value = state("pr_gate");
  for (let round = 1; round <= 5; round += 1) {
    value.stage = "pr_gate";
    applyHumanDecision(value, { gate: "pr", decision: "revise", note: `round ${round}`, decidedAt: "now" }, 5);
  }
  assert.equal(value.stage, "escalated");
  assert.equal(value.loopCounts.code_review, 5);
});

test("PR revisions return to engineering with the owner's note preserved", () => {
  const value = state("pr_gate");
  applyHumanDecision(value, { gate: "pr", decision: "revise", note: "Fix the launch transition", decidedAt: "now" });
  assert.equal(value.stage, "implementation");
  assert.equal(value.decisions.at(-1)?.note, "Fix the launch transition");
});
