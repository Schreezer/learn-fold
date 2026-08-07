import { readFile } from "node:fs/promises";
import path from "node:path";
import { roles, type WorkflowConfig } from "./types.js";

export async function loadConfig(toolRoot: string): Promise<WorkflowConfig> {
  const configPath = process.env.LEARNFOLD_WORKFLOW_CONFIG
    ? path.resolve(process.env.LEARNFOLD_WORKFLOW_CONFIG)
    : path.join(toolRoot, "workflow.config.json");
  const value = JSON.parse(await readFile(configPath, "utf8")) as WorkflowConfig;

  if (
    value.version !== 1
    || !Number.isInteger(value.maxRoundsPerLoop)
    || value.maxRoundsPerLoop < 1
    || value.maxRoundsPerLoop > 5
    || !Number.isInteger(value.turnTimeoutMs)
    || value.turnTimeoutMs < 1_000
    || typeof value.requireCleanWorktreeForEngineer !== "boolean"
  ) {
    throw new Error(`Invalid workflow configuration: ${configPath}`);
  }
  for (const role of roles) {
    const model = value.models[role];
    if (!model || model.candidates.length === 0) {
      throw new Error(`Missing model candidates for role: ${role}`);
    }
  }
  return value;
}
