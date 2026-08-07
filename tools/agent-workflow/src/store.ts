import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { stages, type WorkflowState } from "./types.js";

export class WorkflowStore {
  constructor(private readonly repository: string) {}

  get runsDirectory(): string {
    return path.join(this.repository, ".agent-workflow", "runs");
  }

  pathFor(id: string): string {
    if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw new Error("Invalid workflow id");
    return path.join(this.runsDirectory, `${id}.json`);
  }

  async load(id: string): Promise<WorkflowState> {
    const state = JSON.parse(await readFile(this.pathFor(id), "utf8")) as WorkflowState;
    validateState(state, this.repository, id);
    return state;
  }

  async save(state: WorkflowState): Promise<void> {
    await mkdir(this.runsDirectory, { recursive: true });
    await chmod(path.dirname(this.runsDirectory), 0o700);
    await chmod(this.runsDirectory, 0o700);
    state.updatedAt = new Date().toISOString();
    const destination = this.pathFor(state.id);
    const temporary = `${destination}.${process.pid}.tmp`;
    await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
    await rename(temporary, destination);
  }
}

function validateState(state: WorkflowState, repository: string, id: string): void {
  if (
    state.version !== 1
    || state.id !== id
    || path.resolve(state.repository) !== path.resolve(repository)
    || !stages.includes(state.stage)
    || !["live", "dry-run"].includes(state.executionMode)
    || !Array.isArray(state.runs)
    || !Array.isArray(state.decisions)
    || typeof state.loopCounts !== "object"
    || Object.values(state.loopCounts).some((count) => !Number.isInteger(count) || count < 0 || count > 5)
  ) {
    throw new Error(`Invalid or mismatched workflow checkpoint: ${id}`);
  }
}
