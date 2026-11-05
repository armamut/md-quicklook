// The Ed25519 key that signs releases. The private key stays in the login
// keychain of the maintainer's Mac: it is never printed, except by `backup`.
//   swift scripts/release-key.swift generate        create it, print the public key
//   swift scripts/release-key.swift public          print the public key
//   swift scripts/release-key.swift sign FILE       write FILE.sig
//   swift scripts/release-key.swift backup          print the private key (run it in your own terminal)
//   swift scripts/release-key.swift restore         read a backup from standard input
import CryptoKit
import Foundation
import Security

let service = "md-quicklook-release-key"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func query() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: "release"]
}

func loadKey() -> Curve25519.Signing.PrivateKey? {
    var result: CFTypeRef?
    var request = query()
    request[kSecReturnData as String] = true
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    guard status != errSecItemNotFound else { return nil }
    guard status == errSecSuccess, let raw = result as? Data,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("Could not read the release key (\(status)).") }
    return key
}

func store(_ key: Curve25519.Signing.PrivateKey) {
    guard loadKey() == nil else { fail("A release key exists already: not replacing it.") }
    var item = query()
    item[kSecValueData as String] = key.rawRepresentation
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Could not store the release key (\(status)).") }
}

func requireKey() -> Curve25519.Signing.PrivateKey {
    guard let key = loadKey() else { fail("No release key in the keychain.") }
    return key
}

func publicText(_ key: Curve25519.Signing.PrivateKey) -> String {
    key.publicKey.rawRepresentation.base64EncodedString()
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count) {
case ("generate", 1):
    let key = Curve25519.Signing.PrivateKey()
    store(key)
    print(publicText(key))
case ("public", 1):
    print(publicText(requireKey()))
case ("sign", 2):
    let key = requireKey()
    let file = URL(fileURLWithPath: arguments[1])
    guard let contents = try? Data(contentsOf: file, options: .mappedIfSafe),
          let signature = try? key.signature(for: contents),
          key.publicKey.isValidSignature(signature, for: contents)
    else { fail("Could not sign \(file.path).") }
    do { try signature.write(to: URL(fileURLWithPath: file.path + ".sig")) } catch { fail("\(error)") }
case ("backup", 1):
    print(requireKey().rawRepresentation.base64EncodedString())
case ("restore", 1):
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("That is not a release key.") }
    store(key)
    print(publicText(key))
default:
    fail("usage: release-key generate | public | sign FILE | backup | restore")
}
