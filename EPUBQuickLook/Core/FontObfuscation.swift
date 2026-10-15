//
//  FontObfuscation.swift
//  EPUBQuickLook
//
//  Embedded fonts in many EPUBs are "obfuscated" (XOR-mangled, not encrypted)
//  so they can't be trivially lifted out of the book. Reading systems undo it
//  with a key derived from the book's identifier. Without this step, books
//  fall back to system fonts — one of the visible fidelity gaps vs. calibre.
//
//  IDPF:  https://www.w3.org/publishing/epub3/epub-ocf.html#sec-font-obfuscation
//  Adobe: legacy scheme used by Adobe InDesign / ADE.
//

import Foundation
import CryptoKit

enum FontObfuscation: Equatable {
    case idpf
    case adobe

    static let idpfAlgorithm = "http://www.idpf.org/2008/embedding"
    static let adobeAlgorithm = "http://ns.adobe.com/pdf/enc#RC"

    init?(algorithm: String) {
        switch algorithm.trimmingCharacters(in: .whitespacesAndNewlines) {
        case Self.idpfAlgorithm: self = .idpf
        case Self.adobeAlgorithm: self = .adobe
        default: return nil
        }
    }

    /// Number of leading bytes that are XOR-ed.
    var headerLength: Int { self == .idpf ? 1040 : 1024 }

    /// Derives the XOR key.
    /// - Parameters:
    ///   - uniqueIdentifier: the `dc:identifier` referenced by `package@unique-identifier` (IDPF).
    ///   - allIdentifiers: every `dc:identifier` (Adobe looks for a UUID among them).
    func key(uniqueIdentifier: String?, allIdentifiers: [String]) -> [UInt8]? {
        switch self {
        case .idpf:
            guard let id = uniqueIdentifier else { return nil }
            let stripped = id.unicodeScalars.filter { !["\u{20}", "\u{09}", "\u{0D}", "\u{0A}"].contains($0) }
            let digest = Insecure.SHA1.hash(data: Data(String(String.UnicodeScalarView(stripped)).utf8))
            return Array(digest)
        case .adobe:
            let candidates = ([uniqueIdentifier].compactMap { $0 }) + allIdentifiers
            for c in candidates {
                var s = c.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if s.hasPrefix("urn:uuid:") { s.removeFirst("urn:uuid:".count) }
                let hex = s.filter { $0 != "-" }
                guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { continue }
                var bytes: [UInt8] = []
                var i = hex.startIndex
                while i < hex.endIndex {
                    let j = hex.index(i, offsetBy: 2)
                    bytes.append(UInt8(hex[i..<j], radix: 16)!)
                    i = j
                }
                return bytes
            }
            return nil
        }
    }

    /// XORs the header in place. The operation is its own inverse.
    func apply(to data: inout Data, key: [UInt8]) {
        guard !key.isEmpty else { return }
        let n = min(headerLength, data.count)
        data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            for i in 0..<n { buf[i] ^= key[i % key.count] }
        }
    }
}
