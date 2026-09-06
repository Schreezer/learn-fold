import { describe, expect, it } from "vitest"
import { HostedTelemetry, observedProviderFetch, ProviderStreamObserver } from "../src/telemetry"

const encode = (text: string) => new TextEncoder().encode(text)

describe("Hosted telemetry", () => {
  it("observes Responses reasoning, text, tools and nested usage without logging content", () => {
    const logs: unknown[] = []
    let activity = 0
    const observer = new ProviderStreamObserver((event, fields) => logs.push({ event, ...fields }), () => activity++)
    const events = [
      { type: "response.reasoning_summary_text.delta", delta: "PRIVATE reasoning" },
      { type: "response.reasoning_text.delta", delta: "PRIVATE reasoning" },
      { type: "response.reasoning_summary_text.delta", delta: "" },
      { type: "response.output_text.delta", delta: "PRIVATE answer" },
      { type: "response.output_item.added", item: { type: "function_call", arguments: "PRIVATE arguments" } },
      { type: "response.completed", response: { output: "PRIVATE full answer", usage: {
        input_tokens: 10, output_tokens: 20, total_tokens: 30,
        input_tokens_details: { cached_tokens: 5 }, output_tokens_details: { reasoning_tokens: 12 },
      } } },
    ]
    const bytes = encode(events.map(value => `data: ${JSON.stringify(value)}\n\n`).join(""))
    for (let i = 0; i < bytes.length; i += 7) observer.observe(bytes.slice(i, i + 7))
    observer.finish()
    expect(activity).toBe(2)
    expect(logs).toEqual([
      { event: "provider.first_byte" }, { event: "provider.first_reasoning" },
      { event: "provider.first_text" }, { event: "provider.first_tool" },
      { event: "provider.usage", prompt_tokens: 10, completion_tokens: 20, total_tokens: 30,
        cached_tokens: 5, reasoning_tokens: 12 }, { event: "provider.done" },
    ])
    expect(JSON.stringify(logs)).not.toContain("PRIVATE")
  })

  it("records split SSE milestones without leaking text, reasoning, arguments or errors", () => {
    const logs: unknown[] = []
    const observer = new ProviderStreamObserver((event, fields) => logs.push({ event, ...fields }))
    const input = [
      'data: {"choices":[{"delta":{"reasoning_content":"PRIVATE REASONING"}}]}\r\n\r\n',
      'data: {"choices":[{"delta":{"content":"PRIVATE ANSWER 🦉"}}]}\n\n',
      'data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"PRIVATE TOOL"}}]}}]}\n\n',
      'data: {"usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}\n\n',
      'data: {"error":{"message":"PRIVATE ERROR AND CREDENTIAL"}}\n\n',
      'data: [DONE]\n\n',
    ].join("")
    // Split inside JSON tokens and multi-byte UTF-8 code points.
    const bytes = encode(input)
    for (let i = 0; i < bytes.length; i += 3) observer.observe(bytes.slice(i, i + 3))
    expect(logs).toEqual([
      { event: "provider.first_byte" }, { event: "provider.first_reasoning" },
      { event: "provider.first_text" }, { event: "provider.first_tool" },
      { event: "provider.error_frame" },
      { event: "provider.usage", prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 },
      { event: "provider.done" },
    ])
    expect(JSON.stringify(logs)).not.toContain("PRIVATE")
  })

  it("reports activity only for real nonempty reasoning deltas, including split frames", () => {
    let activity = 0
    const observer = new ProviderStreamObserver(() => {}, () => { activity++ })
    observer.observe(encode('data: {"choices":[{"delta":{"reasoning_'))
    observer.observe(encode('content":"PRIVATE"}}]}\n\n'))
    observer.observe(encode('data: {"choices":[{"delta":{"reasoning_content":""}}]}\n\n'))
    observer.observe(encode('data: {"choices":[{"delta":{"content":"answer"}}]}\n\n'))
    observer.observe(encode(': keepalive\n\ndata: {"usage":{"completion_tokens":42}}\n\n'))
    expect(activity).toBe(1)
  })

  it("aggregates providers that emit cumulative usage on every token", () => {
    const logs: unknown[] = []
    const observer = new ProviderStreamObserver((event, fields) => logs.push({ event, ...fields }))
    for (let i = 1; i <= 2000; i++) {
      observer.observe(encode(`data: {"usage":{"completion_tokens":${i}}}\n\n`))
    }
    observer.finish()
    observer.finish()
    expect(logs).toEqual([{ event: "provider.first_byte" }, { event: "provider.usage", completion_tokens: 2000 }])
  })

  it("bounds buffered events and resumes observation after oversized frames", () => {
    const events: string[] = []
    const observer = new ProviderStreamObserver(event => events.push(event))
    observer.observe(encode('data: {"private":"' + "x".repeat(70_000)))
    observer.observe(encode('"}\n\ndata: {"choices":[{"delta":{"content":"ok"}}]}\n\n'))
    expect(events).toEqual(["provider.first_byte", "provider.oversized_event", "provider.first_text"])
  })

  it("drops arbitrary lifecycle payloads and keeps late provider events on their original request", () => {
    const logs: unknown[] = []
    const telemetry = new HostedTelemetry(() => "opaque-session", entry => logs.push(entry))
    const first = crypto.randomUUID(), second = crypto.randomUUID()
    telemetry.lifecycle({ type: "chat:turn:start", payload: { requestId: first, error: "PRIVATE", messages: "PRIVATE" } })
    const provider = telemetry.providerObservation()
    telemetry.lifecycle({ type: "chat:turn:finish", payload: { requestId: first, status: "completed", durationMs: 10 } })
    telemetry.lifecycle({ type: "chat:turn:start", payload: { requestId: second } })
    provider("provider.stream_closed")
    expect(logs.at(-1)).toMatchObject({ requestID: first, event: "provider.stream_closed" })
    expect(JSON.stringify(logs)).not.toContain("PRIVATE")
  })

  it("forwards exact stream bytes and headers and propagates cancellation", async () => {
    let cancelled = false
    const bytes = encode('data: {"choices":[{"delta":{"content":"hello"}}]}\n\n')
    const transport: typeof fetch = async () => new Response(new ReadableStream({
      start(controller) { controller.enqueue(bytes) },
      cancel() { cancelled = true },
    }), { headers: { "content-type": "text/event-stream", "x-test": "preserved" } })
    const events: string[] = []
    const wrapped = observedProviderFetch(() => event => events.push(event), transport)
    const response = await wrapped("https://provider.example")
    expect(response.headers.get("x-test")).toBe("preserved")
    const reader = response.body!.getReader()
    expect((await reader.read()).value).toEqual(bytes)
    await reader.cancel()
    expect(cancelled).toBe(true)
    expect(events).toContain("provider.stream_cancelled")
    expect(events).toContain("provider.first_text")
    expect(events).not.toContain("provider.stream_error")
  })

  it("preserves non-stream errors and reports transport failure without its body", async () => {
    const events: string[] = []
    const wrapped = observedProviderFetch(() => event => events.push(event), async () =>
      new Response("PRIVATE ERROR", { status: 429 }))
    const response = await wrapped("https://provider.example")
    expect(response.status).toBe(429)
    expect(await response.text()).toBe("PRIVATE ERROR")
    const failed = observedProviderFetch(() => event => events.push(event), async () => { throw Error("PRIVATE") })
    await expect(failed("https://provider.example")).rejects.toThrow("PRIVATE")
    expect(events).toContain("provider.transport_error")
    expect(JSON.stringify(events)).not.toContain("PRIVATE")
  })
})
