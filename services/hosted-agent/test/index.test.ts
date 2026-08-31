import { SELF } from "cloudflare:test"
import { describe, expect, it } from "vitest"

import { DEFAULT_MODEL, OPENCODE_BASE_URL, createHostedModel } from "../src/provider"

describe("hosted agent worker", () => {
  it("protects the health and agent routes", async () => {
    const anonymous = await SELF.fetch("https://agent.test/health")
    expect(anonymous.status).toBe(401)

    const health = await SELF.fetch("https://agent.test/health", {
      headers: { authorization: "Bearer test-access-token" },
    })
    expect(health.status).toBe(200)
    expect(await health.json()).toMatchObject({
      ok: true,
      runtime: "cloudflare-think",
      model: "deepseek-v4-flash",
      capabilities: ["durable-session", "stream-resume", "auto-compaction", "client-tools"],
    })

    const missing = await SELF.fetch("https://agent.test/not-an-agent", {
      headers: { authorization: "Bearer test-access-token" },
    })
    expect(missing.status).toBe(404)
  })

  it("uses the OpenCode Zen Go chat-completions adapter", () => {
    const model = createHostedModel("not-a-real-key")
    expect(OPENCODE_BASE_URL).toBe("https://opencode.ai/zen/go/v1")
    expect(DEFAULT_MODEL).toBe("deepseek-v4-flash")
    expect(model.modelId).toBe("deepseek-v4-flash")
    expect(model.provider).toContain("opencode-zen-go")
  })
})
