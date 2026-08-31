function bearer(request: Request): string | null {
  const authorization = request.headers.get("authorization")
  if (!authorization?.startsWith("Bearer ")) return null
  const token = authorization.slice(7).trim()
  return token.length > 0 ? token : null
}

async function digest(value: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))
}

export async function isAuthorized(request: Request, expectedToken: string): Promise<boolean> {
  const actualToken = bearer(request)
  if (!actualToken || !expectedToken) return false
  return crypto.subtle.timingSafeEqual(await digest(actualToken), await digest(expectedToken))
}

export function unauthorized(): Response {
  return Response.json(
    { error: "unauthorized" },
    {
      status: 401,
      headers: {
        "cache-control": "no-store",
        "content-type": "application/json; charset=utf-8",
        "x-content-type-options": "nosniff",
      },
    },
  )
}
