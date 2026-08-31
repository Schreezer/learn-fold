import { Think, Session, defaultContextOverflowClassifier } from "@cloudflare/think"
import type { TurnContext, TurnConfig } from "@cloudflare/think"
import { routeAgentRequest } from "agents"
import { createCompactFunction } from "agents/experimental/memory/utils"
import { generateText } from "ai"

import { isAuthorized, unauthorized } from "./auth"
import { COURSE_AGENT_PROMPT } from "./course-prompt"
import { createHostedModel, DEFAULT_MODEL } from "./provider"

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
    return createHostedModel(this.env.OPENCODE_API_KEY)
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

  override beforeTurn(context: TurnContext): TurnConfig {
    const workspaceID = workspaceIDFrom(context)
    if (!workspaceID) {
      throw new Error("A valid Learnfold workspaceId is required for every hosted turn.")
    }
    const clientToolNames = Object.keys(context.tools).filter((name) =>
      name === "present_course_plan" || name.startsWith("native-editor-"),
    )
    const userText = lastUserText(context)
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
    return {
      instructions: `${context.system}\n\nCurrent Learnfold workspace_id: ${workspaceID}${approvalInstructions}`,
      activeTools,
      maxSteps: 24,
      sendReasoning: false,
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

    if (!await isAuthorized(request, env.LEARNFOLD_HOSTED_ACCESS_TOKEN)) return unauthorized()
    return (await routeAgentRequest(request, env)) ?? json({ error: "not_found" }, 404)
  },
} satisfies ExportedHandler<HostedEnv>
