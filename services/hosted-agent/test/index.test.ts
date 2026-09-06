import { generateText } from "ai"
import { getAgentByName } from "agents"
import type { TurnContext } from "@cloudflare/think"
import { SELF, env, runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"

import { DEFAULT_MODEL, OPENCODE_BASE_URL, createHostedModel } from "../src/provider"
import { authorizeGuestRoute, enforceGuestTurnLimit, mintGuestToken, verifyGuestToken } from "../src/guest"

describe("hosted agent worker", () => {
  it("issues session-bound guest tokens without a login or provider key", async () => {
    const session = crypto.randomUUID()
    const response = await SELF.fetch(`https://agent.test/guest-session?sessionId=${session}`, {
      method: "POST",
      headers: { authorization: `Guest ${"a".repeat(64)}` },
    })
    expect(response.status).toBe(200)
    expect(response.headers.get("cache-control")).toBe("no-store")
    const { accessToken } = await response.json<{ accessToken: string }>()
    expect(await verifyGuestToken(accessToken, "test-access-token", session)).toMatch(/^[0-9a-f]{64}$/)
    expect(await verifyGuestToken(accessToken, "test-access-token", crypto.randomUUID())).toBeNull()
    expect((await SELF.fetch("https://agent.test/health", {
      headers: { authorization: `Bearer ${accessToken}` },
    })).status).toBe(401)
  })

  it("rejects malformed credentials, forged tokens, and expired tokens", async () => {
    expect((await SELF.fetch("https://agent.test/guest-session?sessionId=invalid", { method: "POST" })).status).toBe(400)
    const session = crypto.randomUUID()
    const token = await mintGuestToken("test-access-token", "a".repeat(64), session, 1000)
    expect(await verifyGuestToken(token, "test-access-token", session, 3_601_000)).toBeNull()
    expect(await verifyGuestToken(token, "wrong-key", session, 1000)).toBeNull()
    expect(await verifyGuestToken(token.replace("a".repeat(64), "b".repeat(64)), "test-access-token", session, 1000)).toBeNull()
  })

  it("isolates guest conversations and blocks non-chat endpoints", async () => {
    const session = crypto.randomUUID()
    async function route(subject: string, suffix = "") {
      const token = await mintGuestToken("test-access-token", subject, session)
      return authorizeGuestRoute(new Request(`https://agent.test/agents/hosted-course-agent/${session}${suffix}`, {
        headers: { authorization: `Bearer ${token}`, upgrade: "websocket" },
      }), "test-access-token")
    }
    const first = await route("a".repeat(64))
    const second = await route("b".repeat(64))
    expect(first?.url).toContain(`guest-${"a".repeat(64)}-${session}`)
    expect(second?.url).not.toBe(first?.url)
    expect(await route("a".repeat(64), "/messages")).toBeNull()
  })

  it("opens the real Think chat protocol with a guest token", async () => {
    const session = crypto.randomUUID()
    const token = await mintGuestToken("test-access-token", "e".repeat(64), session)
    const response = await SELF.fetch(`https://agent.test/agents/hosted-course-agent/${session}`, {
      headers: { authorization: `Bearer ${token}`, upgrade: "websocket" },
    })
    expect(response.status).toBe(101)
    const socket = response.webSocket!
    socket.accept()
    const initial = await new Promise<unknown>((resolve) => {
      socket.addEventListener("message", (event) => {
        const data = JSON.parse(event.data as string)
        if (data.type === "cf_agent_chat_messages") resolve(data.messages)
      })
    })
    expect(initial).toEqual([])
    socket.close(1000)
  })

  it("enforces durable per-guest turn limits across sessions", async () => {
    const subject = "c".repeat(64)
    const budget = env.GuestUsage.getByName(`turns:${subject}`)
    for (let index = 0; index < 59; index++) expect(await budget.consume(60)).toBe(true)
    await enforceGuestTurnLimit(`guest-${subject}-${crypto.randomUUID()}`, env)
    await expect(enforceGuestTurnLimit(`guest-${subject}-${crypto.randomUUID()}`, env)).rejects.toThrow("today's Hosted beta limit")
    await expect(enforceGuestTurnLimit(crypto.randomUUID(), env)).resolves.toBeUndefined()
  })

  it("limits guest token issuance by IP", async () => {
    const ip = "192.0.2.18"
    const { hashIdentity } = await import("../src/guest")
    const budget = env.GuestUsage.getByName(`bootstrap:${await hashIdentity(ip)}`)
    for (let index = 0; index < 120; index++) await budget.consume(120)
    const response = await SELF.fetch(`https://agent.test/guest-session?sessionId=${crypto.randomUUID()}`, {
      method: "POST", headers: { authorization: `Guest ${"d".repeat(64)}`, "cf-connecting-ip": ip },
    })
    expect(response.status).toBe(429)
  })

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

  it("sends the selected reasoning effort through the provider adapter", async () => {
    let sent: Record<string, unknown> = {}
    const transport: typeof fetch = async (_input, init) => {
      sent = JSON.parse(String(init?.body))
      return Response.json({ id: "test", model: DEFAULT_MODEL, created: 1,
        choices: [{ index: 0, message: { role: "assistant", content: "ok" }, finish_reason: "stop" }],
        usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })
    }
    await generateText({ model: createHostedModel("test-key", transport), prompt: "Question",
      providerOptions: { openai: { reasoningEffort: "low" } } })
    expect(sent.reasoning_effort).toBe("low")
    expect(sent.model).toBe(DEFAULT_MODEL)
  })

  it("uses the OpenCode Zen Go chat-completions adapter", () => {
    const model = createHostedModel("not-a-real-key")
    expect(OPENCODE_BASE_URL).toBe("https://opencode.ai/zen/go/v1")
    expect(DEFAULT_MODEL).toBe("deepseek-v4-flash")
    expect(model.modelId).toBe("deepseek-v4-flash")
    expect(model.provider).toContain("opencode-zen-go")
  })
})


describe("Hosted course workspace continuity", () => {
  function context(body?: Record<string, unknown>, continuation = false): TurnContext {
    return { body, continuation, messages: [], tools: {}, system: "Course agent", model: createHostedModel("test-key") }
  }

  it("keeps the workspace for body-less tool continuations in durable storage", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent, state) => {
      await agent.beforeTurn(context({ workspaceId: "course-a" }))
      expect(await state.storage.get("learnfold.workspaceId")).toBe("course-a")
    })
    await runInDurableObject(stub, async (agent) => {
      const result = await agent.beforeTurn(context(undefined, true))
      expect(result.instructions).toContain("Current Learnfold workspace_id: course-a")
    })
  })

  it("uses low reasoning for passage questions and their tool continuations only", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent) => {
      const focused = context({ workspaceId: "course-a" })
      focused.messages = [{ role: "user", content: 'I selected the following passage from the native course page `Lesson` while studying.\n\n<selected_course_passage page_id="lesson" title="Lesson">\nA passage\n</selected_course_passage>\n\nMy question: Explain this.' }]
      expect((await agent.beforeTurn(focused)).providerOptions).toEqual({ openai: { reasoningEffort: "low" } })
      const continuation = { ...focused, body: undefined, continuation: true }
      expect((await agent.beforeTurn(continuation)).providerOptions).toEqual({ openai: { reasoningEffort: "low" } })
      for (const text of ["Build a deep course", "I approve course plan plan-1 revision 1", "Explain what selected_course_passage means"]) {
        const planning = { ...focused, messages: [{ role: "user" as const, content: text }] }
        expect((await agent.beforeTurn(planning)).providerOptions).toBeUndefined()
      }
    })
  })

  it("rejects missing or malformed workspace IDs on new requests", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent) => {
      await expect(agent.beforeTurn(context(undefined, true))).rejects.toThrow("workspaceId")
      await agent.beforeTurn(context({ workspaceId: "course-a" }))
      await expect(agent.beforeTurn(context())).rejects.toThrow("workspaceId")
      await expect(agent.beforeTurn(context({ workspaceId: "../bad" }, true))).rejects.toThrow("workspaceId")
    })
  })

  it("does not allow another course to rebind an existing conversation", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent) => {
      await agent.beforeTurn(context({ workspaceId: "course-a" }))
      await expect(agent.beforeTurn(context({ workspaceId: "course-b" }))).rejects.toThrow("different course")
      expect((await agent.beforeTurn(context(undefined, true))).instructions).toContain("course-a")
    })
  })
})
