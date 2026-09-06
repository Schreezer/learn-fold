// Only timings, protocol milestones and opaque IDs leave this module.
// Never log provider bodies, learner text, tool arguments/results or credentials.
type Fields = Record<string, string | number | boolean>
type Log = (event: string, fields?: Fields) => void
const UUID = /^[a-f0-9-]{36}$/i
const MAX_LINE = 64 * 1024

export class HostedTelemetry {
  private requestID?: string

  constructor(
    private readonly sessionID: () => string,
    private readonly sink: (entry: Fields) => void = (entry) => console.log(entry),
  ) {}

  private write(event: string, fields: Fields = {}, requestID = this.requestID) {
    this.sink({ component: "learnfold.hosted", event, sessionID: this.sessionID(),
      ...(requestID ? { requestID } : {}), ...fields })
  }

  lifecycle(event: { type: string; payload: Record<string, unknown> }) {
    if (!event.type.startsWith("chat:") && event.type !== "message:error") return
    const id = typeof event.payload.requestId === "string" && UUID.test(event.payload.requestId)
      ? event.payload.requestId : undefined
    if (event.type === "chat:turn:start") this.requestID = id
    const fields: Fields = {}
    for (const key of ["durationMs", "timeoutMs", "attempt", "maxAttempts", "delayMs", "generation"]) {
      const value = event.payload[key]
      if (typeof value === "number" && Number.isFinite(value)) fields[key] = value
    }
    if (typeof event.payload.continuation === "boolean") fields.continuation = event.payload.continuation
    if (["completed", "error", "cancelled", "aborted"].includes(String(event.payload.status))) {
      fields.status = String(event.payload.status)
    }
    this.write(event.type, fields, id ?? this.requestID)
    if (event.type === "chat:turn:finish" && id === this.requestID) this.requestID = undefined
  }

  prepared(continuation: boolean, messageCount: number, toolCount: number) {
    this.write("turn.prepared", { continuation, messageCount, toolCount })
  }

  chunk(type: string) {
    // Tool names and arguments are deliberately excluded, including client tools.
    if (["tool-call", "tool-result", "tool-error"].includes(type)) this.write(`model.${type}`)
  }

  providerObservation(): Log {
    // Capture IDs now: a late stream close must not be assigned to the next turn.
    const requestID = this.requestID
    const providerCallID = crypto.randomUUID()
    const started = Date.now()
    return (event, fields = {}) => this.write(event,
      { providerCallID, elapsedMs: Date.now() - started, ...fields }, requestID ?? "")
  }
}

/** Inspect SSE milestones while forwarding the exact original bytes. */
export class ProviderStreamObserver {
  private decoder = new TextDecoder()
  private line = ""
  private discarding = false
  private seen = new Set<string>()
  private usage: Fields = {}
  private usageReported = false

  constructor(private readonly log: Log, private readonly onReasoning: () => void = () => {}) {}

  private first(event: string) {
    if (this.seen.has(event)) return
    this.seen.add(event)
    this.log(event)
  }

  observe(bytes: Uint8Array) {
    if (bytes.length) this.first("provider.first_byte")
    const text = this.decoder.decode(bytes, { stream: true })
    for (const fragment of text.split(/(?<=\n)/)) {
      if (!this.discarding) this.line += fragment
      if (this.line.length > MAX_LINE) {
        this.line = ""
        this.discarding = true
        this.first("provider.oversized_event")
      }
      if (!fragment.endsWith("\n")) continue
      if (!this.discarding) this.consume(this.line.trimEnd())
      this.line = ""
      this.discarding = false
    }
  }

  finish() {
    if (!this.usageReported && Object.keys(this.usage).length) {
      this.usageReported = true
      this.log("provider.usage", this.usage)
    }
  }

  private consume(line: string) {
    if (!line.startsWith("data:")) return
    const data = line.slice(5).trimStart()
    if (data === "[DONE]") { this.finish(); this.first("provider.done"); return }
    try {
      const value = JSON.parse(data)
      if (!value || typeof value !== "object") return
      if (value.error) this.first("provider.error_frame")
      // Responses events carry deltas at the top level, unlike Chat Completions.
      if (["response.reasoning_text.delta", "response.reasoning_summary_text.delta"].includes(value.type)
        && typeof value.delta === "string" && value.delta.length) {
        this.first("provider.first_reasoning")
        this.onReasoning()
      }
      if (value.type === "response.output_text.delta" && typeof value.delta === "string" && value.delta.length) {
        this.first("provider.first_text")
      }
      if ((value.type === "response.output_item.added" && value.item?.type === "function_call")
        || (value.type === "response.function_call_arguments.delta" && value.delta?.length)) {
        this.first("provider.first_tool")
      }
      if (value.type === "response.failed" || value.type === "error") this.first("provider.error_frame")
      for (const choice of Array.isArray(value.choices) ? value.choices : []) {
        const delta = choice?.delta
        if (typeof delta?.reasoning_content === "string" && delta.reasoning_content.length) {
          this.first("provider.first_reasoning")
          this.onReasoning()
        }
        if (typeof delta?.content === "string" && delta.content.length) this.first("provider.first_text")
        if (Array.isArray(delta?.tool_calls) && delta.tool_calls.length) this.first("provider.first_tool")
      }
      const usage = value.response?.usage ?? value.usage
      if (usage && typeof usage === "object") {
        const fields: Fields = {}
        for (const key of ["prompt_tokens", "completion_tokens", "total_tokens"]) {
          if (typeof usage[key] === "number" && Number.isFinite(usage[key])) fields[key] = usage[key]
        }
        for (const [source, target] of [["input_tokens", "prompt_tokens"], ["output_tokens", "completion_tokens"]]) {
          if (typeof usage[source] === "number" && Number.isFinite(usage[source])) fields[target] = usage[source]
        }
        for (const [value, key] of [
          [usage.input_tokens_details?.cached_tokens, "cached_tokens"],
          [usage.output_tokens_details?.reasoning_tokens, "reasoning_tokens"],
        ] as const) {
          if (typeof value === "number" && Number.isFinite(value)) fields[key] = value
        }
        if (Object.keys(fields).length) this.usage = fields
      }
      if (["response.completed", "response.incomplete", "response.failed"].includes(value.type)) {
        this.finish()
        this.first("provider.done")
      }
    } catch { /* Non-JSON keepalives are not failures and are never logged. */ }
  }
}

export function observedProviderFetch(
  start: () => Log,
  transport: typeof fetch = fetch,
  reasoningObserver: () => (() => void) = () => () => {},
): typeof fetch {
  return async (input, init) => {
    const log = start()
    const onReasoning = reasoningObserver()
    log("provider.request")
    let response: Response
    try { response = await transport(input, init) }
    catch (error) { log("provider.transport_error"); throw error }
    log("provider.headers", { status: response.status })
    if (!response.body || !response.headers.get("content-type")?.includes("text/event-stream")) return response
    const observer = new ProviderStreamObserver(log, onReasoning)
    const reader = response.body.getReader()
    let closed = false
    const body = new ReadableStream<Uint8Array>({
      async pull(controller) {
        try {
          const next = await reader.read()
          if (closed) return
          if (next.done) { closed = true; observer.finish(); log("provider.stream_closed"); controller.close(); return }
          observer.observe(next.value)
          controller.enqueue(next.value)
        } catch (error) {
          if (closed) return
          closed = true
          observer.finish()
          log("provider.stream_error")
          controller.error(error)
        }
      },
      async cancel(reason) {
        closed = true
        observer.finish()
        log("provider.stream_cancelled")
        await reader.cancel(reason)
      },
    })
    return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers })
  }
}
