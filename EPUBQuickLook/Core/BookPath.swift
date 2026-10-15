//
//  BookPath.swift
//  EPUBQuickLook
//
//  Path arithmetic for resources inside an EPUB container. All paths are
//  container-relative ("OPS/xhtml/ch01.xhtml"), "/"-separated, percent-decoded,
//  and never escape the container root.
//

import Foundation

enum BookPath {

    /// Resolves a URL reference found in book markup (`href`, `src`, manifest
    /// item, nav link…) against the file that contains it.
    ///
    /// - Returns: the normalized container path (fragment and query removed), or
    ///   `nil` for external URLs (`http:`, `mailto:`, `data:`…), empty
    ///   references, and anything that would escape the container root.
    static func resolve(_ href: String, relativeTo containingFile: String) -> String? {
        let (pathPart, _) = splitFragment(href)
        guard !pathPart.isEmpty, !hasScheme(pathPart) else { return nil }
        let decoded = pathPart.removingPercentEncoding ?? pathPart
        let joined = decoded.hasPrefix("/") ? decoded : directory(of: containingFile) + decoded
        return normalize(joined)
    }

    /// Collapses `.`/`..`/empty segments. Returns `nil` if `..` climbs above the root.
    static func normalize(_ path: String) -> String? {
        var out: [Substring] = []
        for seg in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true) {
            switch seg {
            case ".": continue
            case "..":
                guard !out.isEmpty else { return nil }
                out.removeLast()
            default: out.append(seg)
            }
        }
        return out.isEmpty ? nil : out.joined(separator: "/")
    }

    /// "OPS/xhtml/ch1.xhtml" → "OPS/xhtml/" ; "ch1.xhtml" → ""
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    /// Splits "a/b.xhtml?x=1#frag" into ("a/b.xhtml", "frag"). The query is dropped.
    static func splitFragment(_ href: String) -> (path: String, fragment: String) {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        var path = trimmed
        var fragment = ""
        if let hash = trimmed.firstIndex(of: "#") {
            path = String(trimmed[..<hash])
            fragment = String(trimmed[trimmed.index(after: hash)...])
        }
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        return (path, fragment.removingPercentEncoding ?? fragment)
    }

    /// Percent-encodes each path segment so the path can be appended to a URL.
    static func urlEncoded(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static let segmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;%"))

    private static func hasScheme(_ s: String) -> Bool {
        // RFC 3986: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"
        guard let colon = s.firstIndex(of: ":") else { return false }
        let scheme = s[..<colon]
        guard let first = scheme.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-."))
        return scheme.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
    }
}
