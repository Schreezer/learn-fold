import { env, runDurableObjectAlarm, runInDurableObject, SELF } from "cloudflare:test"
import { describe, expect, it } from "vitest"

const pairPayload = {
  v: 1,
  node_id: "node-test",
  token: "pair-secret",
  host_name: "Aeon",
  relay: "https://relay.example",
}

async function createPairing() {
  const response = await SELF.fetch("https://pair.test/v1/pairing-requests", {
    method: "POST",
    headers: { "x-learnfold-installation": crypto.randomUUID() },
  })
  expect(response.status).toBe(201)
  return response.json<{
    request_id: string
    submit_url: string
    claim_token: string
  }>()
}

describe("pairing broker", () => {
  it("keeps credentials hidden until an authorized claim", async () => {
    const pairing = await createPairing()
    const authorization = { authorization: `Bearer ${pairing.claim_token}` }

    const pending = await SELF.fetch(
      `https://pair.test/v1/pairing-requests/${pairing.request_id}/status`,
      { headers: authorization },
    )
    expect(await pending.json()).toMatchObject({ state: "pending" })

    const submitted = await SELF.fetch(pairing.submit_url, {
      method: "POST",
      body: JSON.stringify(pairPayload),
    })
    expect(submitted.status).toBe(202)

    const ready = await SELF.fetch(
      `https://pair.test/v1/pairing-requests/${pairing.request_id}/status`,
      { headers: authorization },
    )
    const readyBody = await ready.json<Record<string, unknown>>()
    expect(readyBody).toMatchObject({
      state: "ready",
      host: { name: "Aeon", node_id: "node-test" },
    })
    expect(JSON.stringify(readyBody)).not.toContain("pair-secret")

    const claimURL = `https://pair.test/v1/pairing-requests/${pairing.request_id}/claim`
    const claimed = await SELF.fetch(claimURL, { method: "POST", headers: authorization })
    expect(await claimed.json()).toEqual({ pairing_payload: pairPayload })

    // Simulate losing the first response after the broker completed the request.
    const replay = await SELF.fetch(claimURL, { method: "POST", headers: authorization })
    expect(replay.status).toBe(200)
    expect(await replay.json()).toEqual({ pairing_payload: pairPayload })

    const unauthorizedReplay = await SELF.fetch(claimURL, {
      method: "POST",
      headers: { authorization: "Bearer wrong" },
    })
    expect(unauthorizedReplay.status).toBe(401)
    expect(JSON.stringify(await unauthorizedReplay.json())).not.toContain("pair-secret")
  })

  it("rejects the wrong submit and claim tokens", async () => {
    const pairing = await createPairing()
    const badSubmit = new URL(pairing.submit_url)
    badSubmit.searchParams.set("token", "wrong")

    expect((await SELF.fetch(badSubmit, {
      method: "POST",
      body: JSON.stringify(pairPayload),
    })).status).toBe(401)

    expect((await SELF.fetch(
      `https://pair.test/v1/pairing-requests/${pairing.request_id}/status`,
      { headers: { authorization: "Bearer wrong" } },
    )).status).toBe(401)
  })

  it("treats an identical submit retry as a successful idempotent handoff", async () => {
    const pairing = await createPairing()

    expect((await SELF.fetch(pairing.submit_url, {
      method: "POST",
      body: JSON.stringify(pairPayload),
    })).status).toBe(202)

    expect((await SELF.fetch(pairing.submit_url, {
      method: "POST",
      body: JSON.stringify(pairPayload),
    })).status).toBe(202)

    expect((await SELF.fetch(pairing.submit_url, {
      method: "POST",
      body: JSON.stringify({ ...pairPayload, node_id: "different-node" }),
    })).status).toBe(409)
  })

  it("does not disclose a submitted payload after the request expires", async () => {
    const pairing = await createPairing()
    const submitted = await SELF.fetch(pairing.submit_url, {
      method: "POST",
      body: JSON.stringify(pairPayload),
    })
    expect(submitted.status).toBe(202)

    const stub = env.PAIRING_REQUESTS.get(env.PAIRING_REQUESTS.idFromString(pairing.request_id))
    await runInDurableObject(stub, async (_instance, state) => {
      const meta = await state.storage.get<{
        submitHash: ArrayBuffer
        claimHash: ArrayBuffer
        expiresAt: number
      }>("meta")
      expect(meta).toBeDefined()
      await state.storage.put("meta", { ...meta!, expiresAt: Date.now() - 1 })
    })

    const claim = await SELF.fetch(
      `https://pair.test/v1/pairing-requests/${pairing.request_id}/claim`,
      {
        method: "POST",
        headers: { authorization: `Bearer ${pairing.claim_token}` },
      },
    )
    expect(claim.status).toBe(401)
    expect(JSON.stringify(await claim.json())).not.toContain("pair-secret")
  })

  it("clears a retained claim when the authorized client cancels", async () => {
    const pairing = await createPairing()
    const authorization = { authorization: `Bearer ${pairing.claim_token}` }
    expect((await SELF.fetch(pairing.submit_url, {
      method: "POST",
      body: JSON.stringify(pairPayload),
    })).status).toBe(202)

    const claimURL = `https://pair.test/v1/pairing-requests/${pairing.request_id}/claim`
    expect((await SELF.fetch(claimURL, { method: "POST", headers: authorization })).status).toBe(200)
    expect((await SELF.fetch(
      `https://pair.test/v1/pairing-requests/${pairing.request_id}/cancel`,
      { method: "DELETE", headers: authorization },
    )).status).toBe(200)

    const replay = await SELF.fetch(claimURL, { method: "POST", headers: authorization })
    expect(replay.status).toBe(401)
    expect(JSON.stringify(await replay.json())).not.toContain("pair-secret")
  })

  it("clears a retained claim when its expiry alarm runs", async () => {
    const pairing = await createPairing()
    const authorization = { authorization: `Bearer ${pairing.claim_token}` }
    expect((await SELF.fetch(pairing.submit_url, {
      method: "POST",
      body: JSON.stringify(pairPayload),
    })).status).toBe(202)

    const claimURL = `https://pair.test/v1/pairing-requests/${pairing.request_id}/claim`
    expect((await SELF.fetch(claimURL, { method: "POST", headers: authorization })).status).toBe(200)

    const stub = env.PAIRING_REQUESTS.get(env.PAIRING_REQUESTS.idFromString(pairing.request_id))
    expect(await runDurableObjectAlarm(stub)).toBe(true)

    const replay = await SELF.fetch(claimURL, { method: "POST", headers: authorization })
    expect(replay.status).toBe(401)
    expect(JSON.stringify(await replay.json())).not.toContain("pair-secret")
  })
})
