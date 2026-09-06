import { createOpenAI } from "@ai-sdk/openai"

export const OPENCODE_BASE_URL = "https://opencode.ai/zen/go/v1"
export const DEFAULT_MODEL = "deepseek-v4-flash"

export function createHostedModel(apiKey: string, providerFetch?: typeof fetch) {
  return createOpenAI({
    apiKey,
    fetch: providerFetch,
    baseURL: OPENCODE_BASE_URL,
    name: "opencode-zen-go",
  }).chat(DEFAULT_MODEL)
}
