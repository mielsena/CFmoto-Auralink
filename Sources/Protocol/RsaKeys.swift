// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Ported from RsaKeys.kt (mirrors net.easyconn.carman.utils.RSAUtil). The Carbit SDK generates a
// 1024-bit RSA keypair locally on first run:
//   - the bike sends its HUID in cleartext CLIENT_INFO; we "sign" it by RAW RSA-encrypting the UTF-8
//     bytes with our PRIVATE key (PKCS#1 v1.5 padding, NO digest/hash — textbook signing, matching
//     the Kotlin `Cipher.ENCRYPT_MODE` + `RSA/ECB/PKCS1Padding` + private key call exactly). The bike
//     verifies by decrypting with the public key we send alongside it.
//   - `pubkey` in our CLIENT_INFO reply is the X.509 SubjectPublicKeyInfo DER, base64-encoded — the
//     same format `java.security.PublicKey.getEncoded()` produces for an RSA key.
//
// KEY SIZE NOTE: docs/01-PROTOCOL-REFERENCE.md's condensed writeup says 2048-bit; the Kotlin source
// (ground truth per docs/00-README-HANDOFF.md) uses 1024-bit. Followed here for wire compatibility —
// the bike's decompiled SDK may assume a specific key size when parsing/verifying.

import Foundation
import Security

enum RsaKeysError: Error, CustomStringConvertible {
    case keyGenerationFailed(String)
    case exportFailed(String)
    case signFailed(String)

    var description: String {
        switch self {
        case .keyGenerationFailed(let s): return "RsaKeys: key generation failed: \(s)"
        case .exportFailed(let s): return "RsaKeys: export failed: \(s)"
        case .signFailed(let s): return "RsaKeys: sign failed: \(s)"
        }
    }
}

/// Per-install RSA keypair, persisted in the Keychain so it survives app relaunches (the bike may
/// cache our pubkey/HUID pairing across a session — regenerating it every launch would be wasteful,
/// though not protocol-breaking since CLIENT_INFO is re-sent on every connect).
final class RsaKeys {
    static let shared: RsaKeys = {
        do {
            return try RsaKeys()
        } catch {
            // Key generation/Keychain access failing is a hard blocker for pairing (no key → no
            // valid CLIENT_INFO reply → bike refuses/stalls). Surface it loudly via LogBus rather
            // than crash, and fall back to a fresh in-memory-only key so the app still boots.
            Task { await LogBus.shared.log("[RSA] persistent key unavailable (\(error)) — using session-only key") }
            return RsaKeys(inMemory: true)
        }
    }()

    private static let tag = "com.amielsena.auralink.rsa-keypair".data(using: .utf8)!
    private static let keySizeInBits = 1024

    let privateKey: SecKey
    let publicKey: SecKey
    let publicKeyBase64: String

    private init(inMemory: Bool = false) {
        // Best-effort fallback path used only when Keychain-backed generation throws — never expected
        // in normal operation, but guarantees `shared` is always usable.
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: Self.keySizeInBits,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            fatalError("RsaKeys: in-memory fallback key generation failed: \(String(describing: error))")
        }
        privateKey = key
        publicKey = SecKeyCopyPublicKey(key)!
        publicKeyBase64 = (try? Self.x509SPKIBase64(for: publicKey)) ?? ""
    }

    private init() throws {
        if let existing = try Self.loadFromKeychain() {
            privateKey = existing
        } else {
            privateKey = try Self.generateAndStore()
        }
        guard let pub = SecKeyCopyPublicKey(privateKey) else {
            throw RsaKeysError.keyGenerationFailed("no public key derived from private key")
        }
        publicKey = pub
        publicKeyBase64 = try Self.x509SPKIBase64(for: pub)
    }

    /// Raw-RSA-"encrypts" (signs, no digest) `huid`'s UTF-8 bytes with our private key using PKCS#1
    /// v1.5 padding — the `encryptedHUID` field the bike expects in our CLIENT_INFO reply.
    func signHuid(_ huid: String) throws -> String {
        let data = Data(huid.utf8)
        var error: Unmanaged<CFError>?
        // `.rsaSignatureDigestPKCS1v15Raw`: PKCS#1 v1.5 padding applied directly to the given bytes
        // with NO DigestInfo header prepended — i.e. exactly what Java's raw RSA "encrypt with
        // private key" (Cipher.ENCRYPT_MODE, PKCS1Padding, no hashing) produces on the wire.
        guard let sig = SecKeyCreateSignature(
            privateKey, .rsaSignatureDigestPKCS1v15Raw, data as CFData, &error
        ) as Data? else {
            throw RsaKeysError.signFailed(String(describing: error))
        }
        return sig.base64EncodedString()
    }

    /// Decrypts `encrypted` (encrypted by the bike with our public key) using our private key.
    /// Not required by the confirmed CFDL16 handshake (nothing the bike sends us needs this today),
    /// but ported for interface fidelity with RsaKeys.kt in case a future BikeProfile needs it.
    func decrypt(_ encrypted: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(
            privateKey, .rsaEncryptionPKCS1, encrypted as CFData, &error
        ) as Data? else {
            throw RsaKeysError.signFailed(String(describing: error))
        }
        return plain
    }

    // MARK: - Keychain persistence

    private static func loadFromKeychain() throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let key = item {
            // swiftlint:disable:next force_cast — SecKey is a CF type; this cast pattern is the
            // documented way to bridge a SecItemCopyMatching result back to SecKey.
            return (key as! SecKey)
        }
        if status == errSecItemNotFound { return nil }
        throw RsaKeysError.keyGenerationFailed("Keychain query failed: \(status)")
    }

    private static func generateAndStore() throws -> SecKey {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: keySizeInBits,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw RsaKeysError.keyGenerationFailed(String(describing: error))
        }
        return key
    }

    // MARK: - X.509 SubjectPublicKeyInfo wrapping

    /// `SecKeyCopyExternalRepresentation` returns the PKCS#1 `RSAPublicKey` DER for an RSA key, not
    /// the X.509 `SubjectPublicKeyInfo` the Carbit SDK expects (same shape as Java's
    /// `PublicKey.getEncoded()`). Wrap it with the standard `rsaEncryption` AlgorithmIdentifier.
    private static func x509SPKIBase64(for key: SecKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw RsaKeysError.exportFailed(String(describing: error))
        }
        return x509SPKI(fromPKCS1: pkcs1).base64EncodedString()
    }

    /// OID 1.2.840.113549.1.1.1 (rsaEncryption) + NULL params, DER-encoded.
    private static let rsaAlgorithmIdentifier: [UInt8] = [
        0x30, 0x0d,
        0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
        0x05, 0x00,
    ]

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 128 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var len = length
        while len > 0 { bytes.insert(UInt8(len & 0xff), at: 0); len >>= 8 }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    private static func x509SPKI(fromPKCS1 pkcs1: Data) -> Data {
        let bitString: [UInt8] = [0x00] + [UInt8](pkcs1) // 0 unused bits
        let bitStringDer: [UInt8] = [0x03] + derLength(bitString.count) + bitString
        let body = rsaAlgorithmIdentifier + bitStringDer
        let sequence: [UInt8] = [0x30] + derLength(body.count) + body
        return Data(sequence)
    }
}
