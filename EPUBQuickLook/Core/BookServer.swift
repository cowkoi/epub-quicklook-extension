//
//  BookServer.swift
//  EPUBQuickLook
//
//  Maps `epub-ql://book/<container path>` requests to responses. WebKit-free so
//  it can be unit-tested; `BookSchemeHandler` adapts it to WKURLSchemeHandler.
//
//  Serving everything (viewer + book) from one custom-scheme origin means the
//  viewer can measure and style chapter iframes without the private
//  "universal file access" WebKit flags, and nothing is ever extracted to disk.
//

import Foundation

struct BookResponse {
    let status: Int
    let mimeType: String
    let data: Data
    let headers: [String: String]
}

/// Data the viewer page fetches from `/.ql/book.json`.
struct ViewerManifest: Encodable {
    struct Spine: Encodable { let href: String; let bytes: Int; let fixed: Bool }
    struct TOC: Encodable { let title: String; let depth: Int; let idx: Int; let frag: String }
    struct Position: Codable, Equatable { let i: Int; let frac: Double }

    let title: String
    let author: String
    let language: String
    let spine: [Spine]
    let toc: [TOC]
    let prefs: [String: String]
    let position: Position?
    let error: String?

    init(book: EPUBBook, prefs: [String: String], position: Position?) {
        title = book.title
        author = book.author
        language = book.language
        spine = book.spine.map { Spine(href: BookPath.urlEncoded($0.path), bytes: $0.byteSize, fixed: $0.fixedLayout) }
        toc = book.toc.map { TOC(title: $0.title, depth: $0.depth, idx: $0.spineIndex, frag: $0.fragment) }
        self.prefs = prefs
        self.position = position.flatMap { $0.i >= 0 && $0.i < book.spine.count ? $0 : nil }
        error = nil
    }

    init(error: String, title: String) {
        self.title = title; author = ""; language = ""; spine = []; toc = []; prefs = [:]; position = nil
        self.error = error
    }
}

final class BookServer {
    static let scheme = "epub-ql"
    static let host = "book"
    /// Reserved directory for viewer assets; can't collide with real EPUB paths
    /// in practice, and the viewer wins if it ever does.
    static let reserved = ".ql/"
    static var entryURL: URL { URL(string: "\(scheme)://\(host)/\(reserved)viewer.html")! }

    static let viewerCSP = "default-src 'self' \(scheme): data: blob:; script-src 'self' \(scheme):; "
        + "style-src 'self' \(scheme): 'unsafe-inline'; object-src 'none'; base-uri 'self' \(scheme):; form-action 'none'"
    /// Book content: no scripts, no network. Inline styles are allowed (books use them,
    /// and the viewer injects its own stylesheet into each chapter).
    static let contentCSP = "default-src 'self' \(scheme): data: blob:; script-src 'none'; "
        + "style-src 'self' \(scheme): data: 'unsafe-inline'; object-src 'none'; connect-src 'none'; form-action 'none'"

    private let source: BookSource?
    private let book: EPUBBook?
    private let manifest: Data
    private let asset: (String) -> Data?

    /// - Parameters:
    ///   - asset: loads a viewer asset by file name (e.g. from the extension bundle).
    init(source: BookSource?, book: EPUBBook?, manifest: Data, asset: @escaping (String) -> Data?) {
        self.source = source
        self.book = book
        self.manifest = manifest
        self.asset = asset
    }

    func respond(to url: URL) -> BookResponse {
        guard url.scheme == Self.scheme, url.host == Self.host else { return Self.notFound }
        // URL.path is percent-decoded; normalize() rejects any attempt to climb out.
        guard let path = BookPath.normalize(url.path) else { return Self.notFound }

        if path.hasPrefix(Self.reserved) {
            let name = String(path.dropFirst(Self.reserved.count))
            if name == "book.json" {
                return BookResponse(status: 200, mimeType: "application/json", data: manifest, headers: noStore)
            }
            guard Self.viewerAssets.contains(name), let data = asset(name) else { return Self.notFound }
            var h = noStore
            h["Content-Security-Policy"] = Self.viewerCSP
            return BookResponse(status: 200, mimeType: MIMEType.forPath(name, declared: nil), data: data, headers: h)
        }

        guard let source = source, let canon = source.canonicalPath(path), var data = try? source.read(canon) else {
            return Self.notFound
        }
        if let (kind, key) = book?.obfuscatedFonts[canon] { kind.apply(to: &data, key: key) }
        let mime = MIMEType.forPath(canon, declared: book?.mediaTypes[canon])
        var headers = noStore
        headers["Content-Security-Policy"] = Self.contentCSP
        headers["X-Content-Type-Options"] = "nosniff"
        return BookResponse(status: 200, mimeType: mime, data: data, headers: headers)
    }

    static let viewerAssets: Set<String> = ["viewer.html", "viewer.css", "viewer.js"]
    private let noStore = ["Cache-Control": "no-store"]
    static let notFound = BookResponse(status: 404, mimeType: "text/plain", data: Data("Not found".utf8), headers: [:])
}
