import Foundation
import XCTest
@testable import DshClientCore

final class ProfileStoreTests: XCTestCase {
    private func tempStore() -> ProfileStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("profile-store-tests-\(UUID().uuidString)")
        return ProfileStore(directory: directory)
    }

    func testRoundTrip() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        var profile = Profile(user: "tester", host: "example.com", port: 2222, privateKeyPEM: "PEM-BODY")
        profile.knownHosts = ["example.com:2222": "SHA256:abc"]
        try store.save(profile)

        let loaded = try store.load()
        XCTAssertEqual(loaded, profile)
        XCTAssertEqual(loaded?.endpoint, Endpoint(user: "tester", host: "example.com", port: 2222))
        XCTAssertEqual(loaded?.hosts.decide(host: "example.com", port: 2222, fingerprint: "SHA256:abc"), .match)
    }

    func testMissingFileIsNil() throws {
        XCTAssertNil(try tempStore().load())
    }

    func testCorruptFileThrows() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ProfileStoreError, .corrupt)
        }
    }

    func testDelete() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(Profile(user: "u", host: "h", port: 22, privateKeyPEM: "p"))
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testLegacySingleProfileIsReadAsOneEntry() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(Profile(user: "root", host: "192.0.2.10", port: 22, privateKeyPEM: "KEY"))

        let all = try store.loadAll()

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.host, "192.0.2.10")
    }

    func testUpsertKeepsOneEntryPerEndpoint() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.upsert(Profile(user: "root", host: "a", port: 22, privateKeyPEM: "K1"))
        try store.upsert(Profile(user: "root", host: "b", port: 22, privateKeyPEM: "K2"))
        try store.upsert(Profile(user: "root", host: "a", port: 22, privateKeyPEM: "K3"))

        let all = try store.loadAll()

        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first(where: { $0.host == "a" })?.privateKeyPEM, "K3")
    }

    func testRemoveDropsOnlyThatEndpoint() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let keep = Profile(user: "root", host: "a", port: 22, privateKeyPEM: "K1")
        let drop = Profile(user: "root", host: "b", port: 22, privateKeyPEM: "K2")
        try store.saveAll([keep, drop])

        try store.remove(drop)

        XCTAssertEqual(try store.loadAll().map(\.host), ["a"])
    }

    func testListFileIsPrivate() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.saveAll([Profile(user: "root", host: "a", port: 22, privateKeyPEM: "K1")])

        let attributes = try FileManager.default.attributesOfItem(atPath: store.listURL.path)

        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
