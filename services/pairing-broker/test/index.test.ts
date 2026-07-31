import { SELF } from "cloudflare:test"
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
  it("keeps credentials hidden until an authorized one-time claim", async () => {
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

    const replay = await SELF.fetch(claimURL, { method: "POST", headers: authorization })
    expect(replay.ok).toBe(false)
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
})
