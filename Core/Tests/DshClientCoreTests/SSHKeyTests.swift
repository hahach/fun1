import XCTest
@testable import DshClientCore

final class SSHKeyTests: XCTestCase {
    func testRejectsEmptyInput() {
        XCTAssertThrowsError(try SSHKey.loadEd25519("  \n ")) { error in
            XCTAssertEqual(error as? SSHKey.LoadError, .empty)
        }
    }

    func testRejectsEncryptedKey() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        ENCRYPTED
        -----END OPENSSH PRIVATE KEY-----
        """
        XCTAssertThrowsError(try SSHKey.loadEd25519(pem)) { error in
            XCTAssertEqual(error as? SSHKey.LoadError, .encrypted)
        }
    }

    func testRejectsNonOpenSSHKey() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIBOgIBAAJBAK
        -----END RSA PRIVATE KEY-----
        """
        XCTAssertThrowsError(try SSHKey.loadEd25519(pem)) { error in
            XCTAssertEqual(error as? SSHKey.LoadError, .notEd25519)
        }
    }

    func testRejectsCorruptOpenSSHBody() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        not-base64-at-all
        -----END OPENSSH PRIVATE KEY-----
        """
        XCTAssertThrowsError(try SSHKey.loadEd25519(pem)) { error in
            XCTAssertEqual(error as? SSHKey.LoadError, .notEd25519)
        }
    }
}
