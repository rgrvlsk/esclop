// SPDX-License-Identifier: GPL-3.0-or-later
//
// Prints a throwaway EdDSA (Ed25519) key pair for Scripts/update-e2e.sh, in the formats Sparkle
// uses: the private seed (what `sign_update --ed-key-file` reads) and the public key
// (SUPublicEDKey), each base64 on its own line. Never for releases: their key is in the keychain.
//
//   swift Scripts/test-signing-key.swift

import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
