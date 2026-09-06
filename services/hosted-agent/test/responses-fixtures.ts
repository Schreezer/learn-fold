import { DEFAULT_MODEL } from "../src/provider"

export const encode = (value: unknown) => new TextEncoder().encode(`data: ${JSON.stringify(value)}\n\n`)
export const created = { type: "response.created", response: { id: "resp_test", created_at: 1, model: DEFAULT_MODEL } }
export const completed = { type: "response.completed", response: {
  id: "resp_test", usage: { input_tokens: 10, output_tokens: 20, total_tokens: 30 },
} }
export const reasoningStart = [
  created,
  { type: "response.output_item.added", output_index: 0, item: { type: "reasoning", id: "rs_test" } },
  { type: "response.reasoning_summary_part.added", item_id: "rs_test", output_index: 0, summary_index: 0 },
]
export const reasoningDelta = { type: "response.reasoning_summary_text.delta", item_id: "rs_test",
  output_index: 0, summary_index: 0, delta: "PRIVATE SYNTHETIC REASONING" }
export function answerEvents(text = "Visible answer") {
  const item = { type: "message", id: "msg_test", role: "assistant",
    content: [{ type: "output_text", text, annotations: [] }] }
  return [
    { type: "response.output_item.added", output_index: 1, item: { ...item, content: [] } },
    { type: "response.output_text.delta", item_id: item.id, output_index: 1, content_index: 0, delta: text },
    { type: "response.output_item.done", output_index: 1, item },
    completed,
  ]
}
