//
//  ReaderStore.swift
//  EPUBQuickLook
//
//  Persists viewer preferences (text size, theme, width) and the last reading
//  position per book in the extension's sandboxed defaults.
//

import Foundation
import CryptoKit

final class ReaderStore {
    static let shared = ReaderStore(defaults: .standard)

    private let defaults: UserDefaults
    private let prefsKey = "viewerPrefs"
    private let positionsKey = "positions"
    private let maxPositions = 300
    private let allowedPrefs: [String: Set<String>] = [
        "theme": ["light", "sepia", "dark"],
        "wide": ["0", "1", "2"],
    ]

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var prefs: [String: String] {
        defaults.dictionary(forKey: prefsKey) as? [String: String] ?? [:]
    }

    /// Validates and stores prefs sent from the page (untrusted input).
    func savePrefs(_ raw: [String: Any]) {
        var out: [String: String] = [:]
        for (k, v) in raw {
            let s = "\(v)"
            if let allowed = allowedPrefs[k], allowed.contains(s) { out[k] = s }
            if k == "font", let n = Int(s), (50...250).contains(n) { out[k] = String(n) }
        }
        defaults.set(out, forKey: prefsKey)
    }

    /// Key derived from the file path, so it's stable across edits of the file
    /// and doesn't store readable paths in defaults.
    static func bookKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func position(for key: String) -> ViewerManifest.Position? {
        guard let entry = (defaults.dictionary(forKey: positionsKey) as? [String: [Double]])?[key], entry.count == 3 else { return nil }
        return ViewerManifest.Position(i: Int(entry[0]), frac: entry[1])
    }

    func savePosition(_ key: String, index: Int, fraction: Double) {
        guard index >= 0, fraction.isFinite else { return }
        var all = defaults.dictionary(forKey: positionsKey) as? [String: [Double]] ?? [:]
        all[key] = [Double(index), min(max(fraction, 0), 1), Date().timeIntervalSince1970]
        if all.count > maxPositions {   // forget the least recently read books
            let keep = all.sorted { ($0.value.last ?? 0) > ($1.value.last ?? 0) }.prefix(maxPositions)
            all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        defaults.set(all, forKey: positionsKey)
    }
}
