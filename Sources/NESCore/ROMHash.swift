import CryptoKit
import Foundation

/// SHA-256 over ROM images, used to pin a game to the exact dump its
/// decompiled routines and symbol map were derived from.
public enum ROMHash {
    public static func hex(of bytes: [UInt8]) -> String {
        CryptoKit.SHA256.hash(data: Data(bytes))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
