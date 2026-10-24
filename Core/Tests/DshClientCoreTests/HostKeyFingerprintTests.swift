import XCTest
@testable import DshClientCore

final class HostKeyFingerprintTests: XCTestCase {
    func testFingerprintShapeMatchesOpenSSH() {
        // 空输入：SHA256("") 的 base64 是 47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=
        XCTAssertEqual(HostKeyFingerprint.sha256(of: []), "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
    }

    func testMatchesIgnoresWhitespace() {
        let value = "SHA256:abc"
        XCTAssertTrue(HostKeyFingerprint.matches("  " + value + "\n", value))
        XCTAssertFalse(HostKeyFingerprint.matches(value, "SHA256:abd"))
    }

    func testFirstContactThenMatch() {
        var known = KnownHosts()
        XCTAssertEqual(known.decide(host: "example.com", port: 22, fingerprint: "SHA256:a"), .newHost)
        known.trust(host: "example.com", port: 22, fingerprint: "SHA256:a")
        XCTAssertEqual(known.decide(host: "example.com", port: 22, fingerprint: "SHA256:a"), .match)
        XCTAssertEqual(known.decide(host: "example.com", port: 22, fingerprint: "SHA256:b"),
                       .mismatch(known: "SHA256:a"))
    }

    func testPortIsPartOfIdentity() {
        var known = KnownHosts()
        known.trust(host: "example.com", port: 22, fingerprint: "SHA256:a")
        XCTAssertEqual(known.decide(host: "example.com", port: 2222, fingerprint: "SHA256:b"), .newHost)
    }

    func testRoundTripThroughText() {
        var known = KnownHosts()
        known.trust(host: "example.com", port: 22, fingerprint: "SHA256:a")
        known.trust(host: "example.org", port: 2200, fingerprint: "SHA256:b")
        let restored = KnownHosts.parse(known.serialised)
        XCTAssertEqual(restored.decide(host: "example.org", port: 2200, fingerprint: "SHA256:b"), .match)
        XCTAssertEqual(restored.decide(host: "example.com", port: 22, fingerprint: "SHA256:a"), .match)
    }
}
