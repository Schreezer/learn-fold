import XCTest
@testable import Litter

final class NetworkDiscoveryTests: XCTestCase {
    func testTailscaleAvailabilitySurfacesNoticeWhenAppIsInstalled() {
        let availability = TailscaleAvailability(appInstalled: true, likelyActiveTunnel: false)

        XCTAssertTrue(availability.shouldSurfaceDiscoveryNotice)
    }

    func testTailscaleAvailabilitySurfacesNoticeWhenTunnelLooksActive() {
        let availability = TailscaleAvailability(appInstalled: false, likelyActiveTunnel: true)

        XCTAssertTrue(availability.shouldSurfaceDiscoveryNotice)
    }

    func testTailscaleAvailabilitySuppressesNoticeWhenAppIsMissingAndTunnelIsInactive() {
        let availability = TailscaleAvailability(appInstalled: false, likelyActiveTunnel: false)

        XCTAssertFalse(availability.shouldSurfaceDiscoveryNotice)
    }

    func testTailscaleDiscoveryNoticeExplainsUnsupportedSurface() {
        let availability = TailscaleAvailability(appInstalled: true, likelyActiveTunnel: false)

        let notice = NetworkDiscovery.tailscaleDiscoveryNotice(
            for: TailscalePeerParseError.unsupportedSurface,
            availability: availability
        )

        XCTAssertEqual(
            notice,
            "Tailscale returned its web UI instead of a peer list, so peer discovery is unavailable here. Add a server manually with its MagicDNS name or Tailscale IP. Saved servers will still appear here."
        )
    }

    func testTailscaleDiscoveryNoticeSuppressesUnavailableSurfaceWhenTailscaleIsAbsent() {
        let availability = TailscaleAvailability(appInstalled: false, likelyActiveTunnel: false)

        let notice = NetworkDiscovery.tailscaleDiscoveryNotice(
            for: TailscalePeerParseError.unsupportedSurface,
            availability: availability
        )

        XCTAssertNil(notice)
    }

    func testParseTailscalePeerCandidatesFiltersOfflineAndNonIPv4Peers() throws {
        let data = """
        {
          "Peer": {
            "peer-1": {
              "Online": true,
              "HostName": "mac-mini",
              "TailscaleIPs": ["fd7a:115c:a1e0::1", "100.64.0.12"]
            },
            "peer-2": {
              "Online": false,
              "HostName": "offline-host",
              "TailscaleIPs": ["100.64.0.13"]
            },
            "peer-3": {
              "Online": true,
              "DNSName": "ipv6-only.example.ts.net.",
              "TailscaleIPs": ["fd7a:115c:a1e0::2"]
            }
          }
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "http://100.100.100.100/localapi/v0/status")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        let peers = try NetworkDiscovery.parseTailscalePeerCandidates(data: data, response: response)

        XCTAssertEqual(peers, [TailscalePeerIdentity(ip: "100.64.0.12", name: "mac-mini")])
    }

    func testParseTailscalePeerCandidatesRejectsHtmlSurface() {
        let data = """
        <!doctype html>
        <html><body>Tailscale web interface</body></html>
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "http://100.100.100.100/localapi/v0/status")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!

        XCTAssertThrowsError(
            try NetworkDiscovery.parseTailscalePeerCandidates(data: data, response: response)
        )
    }

    func testParseTailscalePeerCandidatesRejectsDeviceStatusPayloadWithoutPeerList() {
        let data = """
        {
          "Status": "Running",
          "DeviceName": "sigkittens-mac-studio",
          "IPv4": "100.113.43.109"
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "http://100.100.100.100/localapi/v0/status")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        XCTAssertThrowsError(
            try NetworkDiscovery.parseTailscalePeerCandidates(data: data, response: response)
        )
    }
}

final class AgentAssistedPairingTests: XCTestCase {
    func testPromptAsksAgentToPerformSetupWithoutDelegatingCommandsToUser() {
        let submitURL = URL(
            string: "https://litter-pairing-broker.chiragmgg.workers.dev/v1/pairing-requests/request/submit?token=secret"
        )!
        let prompt = AgentAssistedPairing.prompt(submitURL: submitURL)

        XCTAssertTrue(prompt.contains("Please do the setup yourself"))
        XCTAssertTrue(prompt.contains("npx -y kittylitter@latest pair"))
        XCTAssertTrue(prompt.contains("HTTP POST that JSON object"))
        XCTAssertTrue(prompt.contains(submitURL.absoluteString))
        XCTAssertTrue(prompt.contains("do not ask me to run a command"))
        XCTAssertTrue(prompt.contains("Do not show me a token or pairing JSON"))
    }

    func testPairingPayloadCandidateExtractsJSONFromAgentResponse() {
        let response = """
        Done. Here is the pairing response:
        ```json
        {"v":1,"node_id":"node-1","token":"secret","relay":"https://relay.example"}
        ```
        """

        XCTAssertEqual(
            AgentAssistedPairing.pairingPayloadCandidate(from: response),
            #"{"v":1,"node_id":"node-1","token":"secret","relay":"https://relay.example"}"#
        )
    }

    func testPairingPayloadCandidateLeavesInvalidResponseForCanonicalParser() {
        XCTAssertEqual(
            AgentAssistedPairing.pairingPayloadCandidate(from: "Hermes could not start kittylitter."),
            "Hermes could not start kittylitter."
        )
    }
}
