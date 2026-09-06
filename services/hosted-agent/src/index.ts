import { Think, Session, defaultContextOverflowClassifier } from "@cloudflare/think"
import type { TurnContext, TurnConfig, ChunkContext } from "@cloudflare/think"
import { routeAgentRequest } from "agents"
import { createCompactFunction } from "agents/experimental/memory/utils"
import { generateText } from "ai"

import { ProviderProgress, PROVIDER_STEP_TIMEOUT_MS } from "./provider-progress"
import { HostedTelemetry, observedProviderFetch } from "./telemetry"
import { isAuthorized, unauthorized } from "./auth"
import { COURSE_AGENT_PROMPT } from "./course-prompt"
import { createHostedModel, DEFAULT_MODEL } from "./provider"
import { authorizeGuestRoute, enforceGuestTurnLimit, guestSession } from "./guest"
export { GuestUsage } from "./guest"

const MAX_WORKSPACE_ID_LENGTH = 128

type HostedEnv = Env & {
  OPENCODE_API_KEY: string
  LEARNFOLD_HOSTED_ACCESS_TOKEN: string
}

function workspaceIDFrom(context: TurnContext): string | null {
  const value = context.body?.workspaceId
  if (typeof value !== "string") return null
  const normalized = value.trim()
  if (!normalized || normalized.length > MAX_WORKSPACE_ID_LENGTH) return null
  return /^[a-zA-Z0-9._-]+$/.test(normalized) ? normalized : null
}

function textFromMessage(message: unknown): string | null {
  if (!message || typeof message !== "object") return null
  const record = message as { role?: unknown; content?: unknown }
  if (record.role !== "user") return null
  if (typeof record.content === "string") return record.content
  if (!Array.isArray(record.content)) return null
  return record.content
    .flatMap((part) => {
      if (!part || typeof part !== "object") return []
      const value = part as { type?: unknown; text?: unknown }
      return value.type === "text" && typeof value.text === "string" ? [value.text] : []
    })
    .join("\n")
}

function lastUserText(context: TurnContext): string | null {
  for (let index = context.messages.length - 1; index >= 0; index -= 1) {
    const text = textFromMessage(context.messages[index])
    if (text !== null) return text
  }
  return null
}

export class HostedCourseAgent extends Think<HostedEnv> {
  private readonly providerProgress = new ProviderProgress()
  private readonly telemetry = new HostedTelemetry(() => this.ctx.id.toString())
  override observability = {
    emit: (event: { type: string; payload: Record<string, unknown> }) => this.telemetry.lifecycle(event),
  }

  override onChunk(context: ChunkContext) {
    this.telemetry.chunk(context.chunk.type)
  }

  // Pinned Think 0.15.1 exposes this protected hook. Keep the real Think stream
  // regression test when upgrading: its watchdog must receive activity chunks.
  protected override _transformInferenceResult(result: Parameters<ProviderProgress["wrap"]>[0]) {
    return this.providerProgress.wrap(result)
  }

  override workspaceBash = false
  override includeMcpTools = false
  override chatRecovery = {
    maxAttempts: 4,
    terminalMessage: "The hosted agent was interrupted. Your conversation is saved; please try again.",
  }
  override chatStreamStallTimeoutMs = 120_000
  override contextOverflow = {
    reactive: true,
    proactive: { maxInputTokens: 96_000 },
  }
  override classifyChatError = defaultContextOverflowClassifier

  override getModel() {
    return createHostedModel(this.env.OPENCODE_API_KEY,
      observedProviderFetch(() => this.telemetry.providerObservation(), fetch,
        () => this.providerProgress.observer()))
  }

  override getSystemPrompt(): string {
    return COURSE_AGENT_PROMPT
  }

  override getSkills() {
    return []
  }

  override configureSession(session: Session): Session {
    return session
      .onCompaction(createCompactFunction({
        summarize: async (prompt) => {
          const result = await generateText({ model: this.getModel(), prompt })
          return result.text
        },
        protectHead: 3,
        tailTokenBudget: 18_000,
        minTailMessages: 4,
      }))
      .compactAfter(72_000)
      .withCachedPrompt()
  }

  override async beforeTurn(context: TurnContext): Promise<TurnConfig> {
    // Think's tool auto-continuations have no request body. Keep the course
    // binding in durable storage so they also survive object restarts.
    const workspaceID = await this.ctx.storage.transaction(async (storage) => {
      const saved = await storage.get<string>("learnfold.workspaceId")
      const supplied = workspaceIDFrom(context)
      const resolved = context.continuation && context.body === undefined ? saved : supplied
      if (!resolved) {
        throw new Error("A valid Learnfold workspaceId is required for every hosted turn.")
      }
      if (saved && saved !== resolved) {
        throw new Error("This Hosted conversation belongs to a different course workspace.")
      }
      if (!saved) await storage.put("learnfold.workspaceId", resolved)
      return resolved
    })
    await enforceGuestTurnLimit(this.name, this.env)
    const clientToolNames = Object.keys(context.tools).filter((name) =>
      name === "present_course_plan" || name.startsWith("native-editor-"),
    )
    const userText = lastUserText(context)
    const focusedQuestion = userText?.startsWith("I selected the following passage from the native course page `") === true
      && userText.includes("\n<selected_course_passage ")
      && userText.includes("</selected_course_passage>\n\nMy question:")
    const approval = userText?.trimStart().startsWith("I approve course plan ") === true
    const directLessonUpdate = approval
      && userText?.includes("Call native-editor-update-page directly") === true
    const activeTools = approval
      ? clientToolNames.filter((name) =>
          name === "native-editor-update-page"
            || (!directLessonUpdate && name === "native-editor-fetch"),
        )
      : clientToolNames
    const approvalInstructions = approval
      ? directLessonUpdate
        ? "\n\nThis is an approved-plan generation turn. The phone has already created the course shell and freshly fetched the exact pending Chapter 1 lesson. You MUST call native-editor-update-page once with the page ID and expected revision in the learner message. Do not fetch, and do not answer with prose before the update succeeds."
        : "\n\nThis is an approved-plan generation turn. The phone has already created the course shell and identified exactly one pending Chapter 1 lesson in the learner message. You MUST use native-editor-fetch, then native-editor-update-page to write that lesson and mark it generated. Do not answer with prose before both tool calls succeed."
      : ""
    this.telemetry.prepared(context.continuation, context.messages.length, activeTools.length)
    return {
      instructions: `${context.system}\n\nCurrent Learnfold workspace_id: ${workspaceID}${approvalInstructions}`,
      activeTools,
      maxSteps: this.name.startsWith("guest-") ? 12 : 24,
      maxOutputTokens: this.name.startsWith("guest-") ? 8192 : undefined,
      sendReasoning: false,
      // Genuine activity extends idle waits, but each model step stays bounded.
      timeout: { stepMs: PROVIDER_STEP_TIMEOUT_MS },
      // Focused clarification should not spend minutes on default-high reasoning.
      // Keep planning/generation defaults and reasoning enabled for correctness.
      ...(focusedQuestion ? { providerOptions: { openai: { reasoningEffort: "low" } } } : {}),
    }
  }
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  })
}

export default {
  async fetch(request: Request, env: HostedEnv): Promise<Response> {
    const url = new URL(request.url)
    if (url.pathname === "/guest-session" && request.method === "POST") {
      return guestSession(request, env, env.LEARNFOLD_HOSTED_ACCESS_TOKEN)
    }
    if (url.pathname === "/health" && request.method === "GET") {
      if (!await isAuthorized(request, env.LEARNFOLD_HOSTED_ACCESS_TOKEN)) return unauthorized()
      return json({
        ok: true,
        runtime: "cloudflare-think",
        model: DEFAULT_MODEL,
        protocol: "cf-agent-chat-v1",
        capabilities: ["durable-session", "stream-resume", "auto-compaction", "client-tools"],
      })
    }

    if (!await isAuthorized(request, env.LEARNFOLD_HOSTED_ACCESS_TOKEN)) {
      if (env.GUEST_BETA_ENABLED !== "true") return unauthorized()
      const guestRequest = await authorizeGuestRoute(request, env.LEARNFOLD_HOSTED_ACCESS_TOKEN)
      if (!guestRequest) return unauthorized()
      return (await routeAgentRequest(guestRequest, env)) ?? json({ error: "not_found" }, 404)
    }
    return (await routeAgentRequest(request, env)) ?? json({ error: "not_found" }, 404)
  },
} satisfies ExportedHandler<HostedEnv>
