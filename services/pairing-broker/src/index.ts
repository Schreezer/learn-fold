import { DurableObject } from "cloudflare:workers"

const REQUEST_TTL_MS = 10 * 60 * 1_000
const MAX_BODY_BYTES = 8 * 1_024

interface PairPayload {
  v: number
  node_id: string
  token: string
  host_name?: string
  relay?: string | null
}

interface PairingMeta {
  submitHash: ArrayBuffer
  claimHash: ArrayBuffer
  expiresAt: number
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

function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32))
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "")
}

async function digest(token: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(token))
}

async function readBoundedJSON(request: Request): Promise<unknown> {
  const length = Number(request.headers.get("content-length") ?? "0")
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
    throw new Error("body_too_large")
  }

  const reader = request.body?.getReader()
  if (!reader) throw new Error("missing_body")

  const chunks: Uint8Array[] = []
  let size = 0
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    size += value.byteLength
    if (size > MAX_BODY_BYTES) {
      await reader.cancel()
      throw new Error("body_too_large")
    }
    chunks.push(value)
  }

  const merged = new Uint8Array(size)
  let offset = 0
  for (const chunk of chunks) {
    merged.set(chunk, offset)
    offset += chunk.byteLength
  }
  return JSON.parse(new TextDecoder().decode(merged))
}

function boundedString(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max
}

function parsePairPayload(value: unknown): PairPayload | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  const candidate = value as Record<string, unknown>
  if (!Number.isInteger(candidate.v) || (candidate.v as number) < 1) return null
  if (!boundedString(candidate.node_id, 512)) return null
  if (!boundedString(candidate.token, 2_048)) return null
  if (candidate.host_name !== undefined && !boundedString(candidate.host_name, 255)) return null
  if (candidate.relay !== undefined && candidate.relay !== null) {
    if (!boundedString(candidate.relay, 2_048)) return null
    try {
      if (new URL(candidate.relay).protocol !== "https:") return null
    } catch {
      return null
    }
  }
  return {
    v: candidate.v as number,
    node_id: candidate.node_id,
    token: candidate.token,
    ...(candidate.host_name === undefined ? {} : { host_name: candidate.host_name }),
    ...(candidate.relay === undefined ? {} : { relay: candidate.relay }),
  }
}

function samePairPayload(left: PairPayload, right: PairPayload): boolean {
  return left.v === right.v
    && left.node_id === right.node_id
    && left.token === right.token
    && left.host_name === right.host_name
    && left.relay === right.relay
}

function bearer(request: Request): string | null {
  const authorization = request.headers.get("authorization")
  return authorization?.startsWith("Bearer ") ? authorization.slice(7) : null
}

function requestStub(env: Env, requestId: string): DurableObjectStub<PairingRequest> | null {
  try {
    return env.PAIRING_REQUESTS.get(env.PAIRING_REQUESTS.idFromString(requestId))
  } catch {
    return null
  }
}

function forward(stub: DurableObjectStub<PairingRequest>, path: string, init: RequestInit): Promise<Response> {
  return stub.fetch(new Request(`https://pairing.internal${path}`, init))
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)
    const parts = url.pathname.split("/").filter(Boolean)

    if (request.method === "POST" && url.pathname === "/v1/pairing-requests") {
      const rateKey = request.headers.get("cf-connecting-ip")
        ?? request.headers.get("x-learnfold-installation")
        ?? "unknown"
      const rate = await env.PAIRING_RATE_LIMITER.limit({ key: rateKey.slice(0, 128) })
      if (!rate.success) return json({ error: "rate_limited" }, 429)

      const id = env.PAIRING_REQUESTS.newUniqueId()
      const submitToken = randomToken()
      const claimToken = randomToken()
      const expiresAt = Date.now() + REQUEST_TTL_MS
      const stub = env.PAIRING_REQUESTS.get(id)
      const initialized = await forward(stub, "/initialize", {
        method: "POST",
        body: JSON.stringify({
          submitHash: Array.from(new Uint8Array(await digest(submitToken))),
          claimHash: Array.from(new Uint8Array(await digest(claimToken))),
          expiresAt,
        }),
      })
      if (!initialized.ok) return json({ error: "initialization_failed" }, 500)

      const requestId = id.toString()
      return json({
        request_id: requestId,
        submit_url: `${url.origin}/v1/pairing-requests/${requestId}/submit?token=${encodeURIComponent(submitToken)}`,
        claim_token: claimToken,
        expires_at: new Date(expiresAt).toISOString(),
      }, 201)
    }

    if (parts.length !== 4 || parts[0] !== "v1" || parts[1] !== "pairing-requests") {
      return json({ error: "not_found" }, 404)
    }

    const [, , requestId, action] = parts
    const stub = requestStub(env, requestId)
    if (!stub) return json({ error: "not_found" }, 404)

    if (request.method === "POST" && action === "submit") {
      const token = url.searchParams.get("token")
      if (!token) return json({ error: "unauthorized" }, 401)
      let body: unknown
      try {
        body = await readBoundedJSON(request)
      } catch (error) {
        return json({ error: error instanceof SyntaxError ? "invalid_json" : "invalid_body" }, 400)
      }
      const payload = parsePairPayload(body)
      if (!payload) return json({ error: "invalid_pairing_payload" }, 400)
      return forward(stub, "/submit", {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify(payload),
      })
    }

    const claimToken = bearer(request)
    if (!claimToken) return json({ error: "unauthorized" }, 401)
    if (request.method === "GET" && action === "status") {
      return forward(stub, "/status", { headers: { authorization: `Bearer ${claimToken}` } })
    }
    if (request.method === "POST" && action === "claim") {
      return forward(stub, "/claim", {
        method: "POST",
        headers: { authorization: `Bearer ${claimToken}` },
      })
    }
    if (request.method === "DELETE" && action === "cancel") {
      return forward(stub, "/cancel", {
        method: "DELETE",
        headers: { authorization: `Bearer ${claimToken}` },
      })
    }
    return json({ error: "not_found" }, 404)
  },
} satisfies ExportedHandler<Env>

export class PairingRequest extends DurableObject<Env> {
  constructor(state: DurableObjectState, env: Env) {
    super(state, env)
  }

  private async authorize(request: Request, kind: "submit" | "claim"): Promise<PairingMeta | null> {
    const token = bearer(request)
    const meta = await this.ctx.storage.get<PairingMeta>("meta")
    if (!token || !meta || Date.now() >= meta.expiresAt) return null
    const expected = kind === "submit" ? meta.submitHash : meta.claimHash
    return crypto.subtle.timingSafeEqual(await digest(token), expected) ? meta : null
  }

  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname

    if (request.method === "POST" && path === "/initialize") {
      if (await this.ctx.storage.get("meta")) return json({ error: "already_initialized" }, 409)
      const raw = await request.json<{
        submitHash: number[]
        claimHash: number[]
        expiresAt: number
      }>()
      const meta: PairingMeta = {
        submitHash: new Uint8Array(raw.submitHash).buffer,
        claimHash: new Uint8Array(raw.claimHash).buffer,
        expiresAt: raw.expiresAt,
      }
      await this.ctx.storage.put("meta", meta)
      await this.ctx.storage.setAlarm(meta.expiresAt)
      return json({ ok: true }, 201)
    }

    if (request.method === "POST" && path === "/submit") {
      if (!await this.authorize(request, "submit")) return json({ error: "unauthorized_or_expired" }, 401)
      const payload = await request.json<PairPayload>()
      const accepted = await this.ctx.storage.transaction(async (transaction) => {
        const stored = await transaction.get<PairPayload>("payload")
        if (stored) return samePairPayload(stored, payload)
        await transaction.put("payload", payload)
        return true
      })
      if (!accepted) return json({ error: "already_submitted" }, 409)
      return json({ ok: true }, 202)
    }

    if (request.method === "GET" && path === "/status") {
      const meta = await this.authorize(request, "claim")
      if (!meta) return json({ error: "unauthorized_or_expired" }, 401)
      const payload = await this.ctx.storage.get<PairPayload>("payload")
      if (!payload) return json({ state: "pending", expires_at: new Date(meta.expiresAt).toISOString() })
      return json({
        state: "ready",
        expires_at: new Date(meta.expiresAt).toISOString(),
        host: {
          name: payload.host_name ?? null,
          node_id: payload.node_id,
        },
      })
    }

    if (request.method === "POST" && path === "/claim") {
      if (!await this.authorize(request, "claim")) return json({ error: "unauthorized_or_expired" }, 401)
      const payload = await this.ctx.storage.get<PairPayload>("payload")
      if (!payload) return json({ error: "not_ready" }, 409)
      await this.ctx.storage.deleteAll()
      return json({ pairing_payload: payload })
    }

    if (request.method === "DELETE" && path === "/cancel") {
      if (!await this.authorize(request, "claim")) return json({ error: "unauthorized_or_expired" }, 401)
      await this.ctx.storage.deleteAll()
      return json({ ok: true })
    }

    return json({ error: "not_found" }, 404)
  }

  async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll()
  }
}
