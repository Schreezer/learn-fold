/** Activity only: provider reasoning text never enters the browser/mobile stream. */
export const PROVIDER_PROGRESS_TYPE = "data-hosted-provider-progress"
export const PROVIDER_STEP_TIMEOUT_MS = 180_000
const MIN_PROGRESS_INTERVAL_MS = 1_000

type StreamResult = {
  toUIMessageStream(options?: { sendReasoning?: boolean; onError?: (error: unknown) => string }): AsyncIterable<unknown>
  output?: PromiseLike<unknown>
}

class ProgressChannel {
  private closed = false
  private last = -Infinity
  private wake?: () => void
  private pending = false

  report() {
    const now = Date.now()
    if (this.closed || now - this.last < MIN_PROGRESS_INTERVAL_MS) return
    this.last = now
    this.pending = true
    this.wake?.()
  }

  wait(): Promise<void> {
    if (this.pending || this.closed) return Promise.resolve()
    return new Promise((resolve) => { this.wake = resolve })
  }

  take() { this.pending = false; this.wake = undefined }
  close() { this.closed = true; this.wake?.(); this.wake = undefined }
}

/**
 * Think 0.15.1 watches the filtered UI stream, so hidden reasoning cannot reset
 * its inactivity deadline. Merge real provider activity into that same stream.
 * The channel is captured per fetch; late callbacks cannot touch a newer turn.
 */
export class ProviderProgress {
  private active?: ProgressChannel

  observer(): () => void {
    const channel = this.active
    return () => channel?.report()
  }

  wrap(result: StreamResult): StreamResult {
    const channel = new ProgressChannel()
    this.active = channel
    return {
      ...result,
      toUIMessageStream: (options) => {
        const source = result.toUIMessageStream(options)
        const owner = this
        return (async function* () {
          const iterator = source[Symbol.asyncIterator]()
          // Keep exactly one source read pending; activity never starts another.
          let next = iterator.next().then((value) => ({ source: true as const, value }))
          try {
            while (true) {
              const event = await Promise.race([
                next,
                channel.wait().then(() => ({ source: false as const })),
              ])
              if (event.source) {
                if (event.value.done) break
                const chunk = event.value.value
                // AI SDK 7 emits deadline expiry as an abort chunk. Think 0.15.1
                // otherwise completes it without an error; convert only SDK
                // timeouts, preserving actual user cancellation semantics.
                if (chunk && typeof chunk === "object"
                  && "type" in chunk && chunk.type === "abort"
                  && "reason" in chunk && typeof chunk.reason === "string"
                  && chunk.reason.startsWith("TimeoutError:")) {
                  yield { type: "error", errorText: "Hosted took too long to finish this reply. Please try again." }
                } else {
                  yield chunk
                }
                next = iterator.next().then((value) => ({ source: true as const, value }))
              } else {
                channel.take()
                yield { type: PROVIDER_PROGRESS_TYPE, transient: true, data: { phase: "reasoning" } }
              }
            }
          } finally {
            channel.close()
            if (owner.active === channel) owner.active = undefined
            // Think aborts the inference signal before closing a stalled or
            // cancelled iterator; returning also releases the SDK stream reader.
            await iterator.return?.()
          }
        })()
      },
    }
  }
}
