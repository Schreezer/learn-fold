import { SELF, env, runInDurableObject } from "cloudflare:test"
import { getAgentByName } from "agents"
import { describe, expect, it } from "vitest"
import { ProviderProgress, PROVIDER_PROGRESS_TYPE } from "../src/provider-progress"

const encode = (value: unknown) => new TextEncoder().encode(`data: ${JSON.stringify(value)}\n\n`)
const delta = (value: Record<string, unknown>) => ({ id: "test", object: "chat.completion.chunk", created: 1,
  model: "deepseek-v4-flash", choices: [{ index: 0, delta: value, finish_reason: null }] })

// The production Think agent, production fetch observer, actual OpenAI adapter,
// real SDK UI stream, real Think watchdog, and real authenticated WebSocket.
async function runStream(mode: "answer" | "silent" | "cancel" | "bound") {
  const name = `test-progress-${crypto.randomUUID()}`
  const stub = await getAgentByName(env.HostedCourseAgent, name)
  let aborted = false
  const events: string[] = []
  await runInDurableObject(stub, (agent) => {
    agent.chatStreamStallTimeoutMs = mode === "answer" ? 1_500 : 200
    agent.chatRecovery = { maxAttempts: 0, terminalMessage: "Stopped" }
    agent.observability = { emit: (event) => { events.push(event.type) } }
    if (mode === "bound") {
      const before = agent.beforeTurn.bind(agent)
      agent.beforeTurn = async (context) => ({ ...await before(context), timeout: { stepMs: 150 } })
    }
    const getModel = agent.getModel.bind(agent)
    agent.getModel = () => {
      const original = globalThis.fetch
      // getModel synchronously captures fetch in the production observer.
      globalThis.fetch = async (_input, init) => {
        let tick: ReturnType<typeof setInterval> | undefined
        let end: ReturnType<typeof setTimeout> | undefined
        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            const stop = () => { clearInterval(tick); clearTimeout(end) }
            init?.signal?.addEventListener("abort", () => {
              aborted = true; stop(); controller.error(init.signal?.reason)
            }, { once: true })
            if (mode !== "silent") {
              controller.enqueue(encode(delta({ reasoning_content: "PRIVATE SYNTHETIC REASONING" })))
              tick = setInterval(() => controller.enqueue(encode(delta({ reasoning_content: "PRIVATE SYNTHETIC REASONING" }))), 100)
            }
            if (mode === "answer") end = setTimeout(() => {
              stop()
              controller.enqueue(encode(delta({ content: "Visible answer" })))
              controller.enqueue(encode({ ...delta({}), choices: [{ index: 0, delta: {}, finish_reason: "stop" }] }))
              controller.enqueue(new TextEncoder().encode("data: [DONE]\n\n"))
              controller.close()
            }, 2_200)
          },
          cancel() { aborted = true; clearInterval(tick); clearTimeout(end) },
        })
        return new Response(stream, { headers: { "content-type": "text/event-stream" } })
      }
      try { return getModel() } finally { globalThis.fetch = original }
    }
  })
  const response = await SELF.fetch(`https://agent.test/agents/hosted-course-agent/${name}`, {
    headers: { authorization: "Bearer test-access-token", upgrade: "websocket" },
  })
  expect(response.status).toBe(101)
  const socket = response.webSocket!
  socket.accept()
  const frames: Record<string, unknown>[] = [], chunks: Record<string, unknown>[] = []
  const request = crypto.randomUUID()
  let sent = false, cancelled = false
  await new Promise<void>((resolve, reject) => {
    const deadline = setTimeout(() => { socket.close(); reject(Error("Test stream did not settle")) }, 6_000)
    socket.addEventListener("message", (event) => {
      const frame = JSON.parse(event.data as string)
      frames.push(frame)
      if (frame.type === "cf_agent_chat_messages" && !sent) {
        sent = true
        socket.send(JSON.stringify({ type: "cf_agent_use_chat_request", id: request,
          init: { method: "POST", body: JSON.stringify({ workspaceId: "course-test", clientTools: [],
            messages: [{ id: crypto.randomUUID(), role: "user", parts: [{ type: "text", text: "Explain this" }] }] }) } }))
      }
      if (frame.type !== "cf_agent_use_chat_response" || frame.id !== request) return
      if (frame.body && !frame.error) {
        try { chunks.push(JSON.parse(frame.body)) } catch { /* Only inspect protocol chunks. */ }
      }
      if (mode === "cancel" && !cancelled && chunks.some(c => c.type === PROVIDER_PROGRESS_TYPE)) {
        cancelled = true
        socket.send(JSON.stringify({ type: "cf_agent_chat_request_cancel", id: request }))
      }
      if (frame.done) { clearTimeout(deadline); resolve() }
    })
  })
  socket.close()
  await runInDurableObject(stub, () => {})
  return { frames, chunks, events, aborted, stub }
}

describe("provider reasoning activity", () => {
  it("keeps real Think watchdog alive while reasoning without leaking or persisting reasoning", async () => {
    const result = await runStream("answer")
    expect(result.events).not.toContain("chat:stream:stalled")
    expect(result.chunks.filter(c => c.type === PROVIDER_PROGRESS_TYPE).length).toBeGreaterThanOrEqual(2)
    expect(result.chunks.filter(c => c.type === "text-delta").map(c => c.delta).join("")).toBe("Visible answer")
    expect(JSON.stringify(result.frames)).not.toContain("PRIVATE SYNTHETIC")
    await runInDurableObject(result.stub, (agent) => {
      expect(JSON.stringify(agent.messages)).not.toContain("PRIVATE SYNTHETIC")
      expect(JSON.stringify(agent.messages)).not.toContain(PROVIDER_PROGRESS_TYPE)
    })
  })

  it("still cancels a genuinely silent provider through Think's watchdog", async () => {
    const result = await runStream("silent")
    expect(result.events).toContain("chat:stream:stalled")
    expect(result.aborted).toBe(true)
    expect(result.chunks.some(c => c.type === PROVIDER_PROGRESS_TYPE)).toBe(false)
  })

  it("propagates user cancellation during hidden reasoning", async () => {
    const result = await runStream("cancel")
    expect(result.aborted).toBe(true)
    expect(result.events).not.toContain("chat:stream:stalled")
  })

  it("bounds continuously reasoning model steps even with active progress", async () => {
    const result = await runStream("bound")
    expect(result.chunks.some(c => c.type === "error") || result.frames.some(f => f.error === true)).toBe(true)
    expect(result.aborted).toBe(true)
    expect(result.events).not.toContain("chat:stream:stalled")
  })

  it("isolates late callbacks from completed streams and subsequent turns", async () => {
    const progress = new ProviderProgress()
    const first = progress.wrap({ async *toUIMessageStream() { yield { type: "start" } } })
    const late = progress.observer()
    for await (const _ of first.toUIMessageStream()) { /* Drain the first turn. */ }
    const second = progress.wrap({ async *toUIMessageStream() { yield { type: "start" } } })
    late()
    const chunks = []
    for await (const chunk of second.toUIMessageStream()) chunks.push(chunk)
    expect(chunks).toEqual([{ type: "start" }])
  })
})
