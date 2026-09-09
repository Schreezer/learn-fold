import { createOpenAI } from "@ai-sdk/openai"
import { defaultSettingsMiddleware, wrapLanguageModel } from "ai"

export const OPENCODE_BASE_URL = "https://opencode.ai/zen/go/v1"
export const DEFAULT_MODEL = "gpt-5.6-luna"
const PROVIDER_USER_AGENT = "learnfold-hosted-agent/1.0"

function sessionAwareFetch(sessionID: string, transport: typeof fetch): typeof fetch {
  return async (input, init) => {
    const headers = new Headers(input instanceof Request ? input.headers : undefined)
    new Headers(init?.headers).forEach((value, key) => headers.set(key, value))
    headers.set("x-opencode-session", sessionID)
    headers.set("user-agent", PROVIDER_USER_AGENT)
    return transport(input, { ...init, headers })
  }
}

export function createHostedModel(
  apiKey: string,
  providerFetch: typeof fetch = fetch,
  sessionID?: string,
) {
  const transport = sessionID ? sessionAwareFetch(sessionID, providerFetch) : providerFetch
  const model = createOpenAI({
    apiKey,
    fetch: transport,
    baseURL: OPENCODE_BASE_URL,
    name: "opencode-zen-go",
  }).responses(DEFAULT_MODEL)
  // Think owns durable history. Replay complete messages/tool results rather
  // than depending on provider-side stored response/item IDs.
  return wrapLanguageModel({ model, middleware: defaultSettingsMiddleware({
    settings: { providerOptions: { openai: { store: false } } },
  }) })
}
