export const agentResultSchema = {
  type: "object",
  properties: {
    verdict: { type: "string", enum: ["pass", "revise", "blocked"] },
    summary: { type: "string" },
    findings: { type: "array", items: { type: "string" } },
    evidence: { type: "array", items: { type: "string" } },
    nextPrompt: { type: "string" },
  },
  required: ["verdict", "summary", "findings", "evidence", "nextPrompt"],
  additionalProperties: false,
} as const;
