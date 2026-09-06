import { createOpenAI } from "@ai-sdk/openai"
import { defaultSettingsMiddleware, wrapLanguageModel } from "ai"

export const OPENCODE_BASE_URL = "https://opencode.ai/zen/go/v1"
export const DEFAULT_MODEL = "gpt-5.6-luna"

export function createHostedModel(apiKey: string, providerFetch?: typeof fetch) {
  const model = createOpenAI({
    apiKey,
    fetch: providerFetch,
    baseURL: OPENCODE_BASE_URL,
    name: "opencode-zen-go",
  }).responses(DEFAULT_MODEL)
  // Think owns durable history. Replay complete messages/tool results rather
  // than depending on provider-side stored response/item IDs.
  return wrapLanguageModel({ model, middleware: defaultSettingsMiddleware({
    settings: { providerOptions: { openai: { store: false } } },
  }) })
}
