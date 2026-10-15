//
//  EPUBBook.swift
//  EPUBQuickLook
//
//  Parses the container, package document (OPF), table of contents (EPUB 3
//  nav or EPUB 2 NCX) and encryption manifest into a model the viewer uses.
//  Only XML is read here; chapter content is served untouched, on demand.
//

import Foundation

struct SpineItem: Equatable {
    let path: String          // container path
    let mediaType: String
    let byteSize: Int
    let fixedLayout: Bool
}

struct TOCEntry: Equatable {
    let title: String
    let depth: Int
    let spineIndex: Int
    let fragment: String
}

enum EPUBError: LocalizedError, Equatable {
    case noPackageDocument
    case emptySpine
    case drmProtected

    var errorDescription: String? {
        switch self {
        case .noPackageDocument: return "This file doesn't contain an EPUB package document (OPF)."
        case .emptySpine: return "This EPUB has no readable chapters."
        case .drmProtected: return "This book is DRM-protected, so its pages can't be previewed."
        }
    }
}

struct EPUBBook {
    let title: String
    let author: String
    let language: String
    let packagePath: String
    let spine: [SpineItem]
    let toc: [TOCEntry]
    let uniqueIdentifier: String?
    /// Declared media types by container path (from the manifest).
    let mediaTypes: [String: String]
    /// Obfuscated fonts by container path, with the de-obfuscation key.
    let obfuscatedFonts: [String: (FontObfuscation, [UInt8])]

    // MARK: Parsing

    static func parse(_ source: BookSource) throws -> EPUBBook {
        let opfPath = try locatePackage(source)
        let opf = try xml(source, opfPath)

        // Direct child traversal instead of XPath: XPath over a 4,000-item
        // manifest and 600-entry TOC dominated parse time on large textbooks.
        guard let packageEl = opf.rootElement() else { throw EPUBError.noPackageDocument }
        let metadata = packageEl.child("metadata")
        func text(_ name: String) -> String {
            (metadata?.child(name)?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let title = text("title")
        let author = text("creator")
        let language = text("language")

        // Identifiers (needed for font de-obfuscation)
        let uidRef = packageEl.attr("unique-identifier")
        let idNodes = metadata?.children("identifier") ?? []
        let identifiers = idNodes.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let uniqueIdentifier = idNodes.first { $0.attribute(forName: "id")?.stringValue == uidRef }?
            .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? identifiers.first

        // Global rendition:layout
        let metas = metadata?.children("meta") ?? []
        let globalFixed = metas.contains {
            ($0.attribute(forName: "property")?.stringValue == "rendition:layout"
                && $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == "pre-paginated")
            || ($0.attribute(forName: "name")?.stringValue == "fixed-layout"        // Apple/Kobo legacy
                && $0.attribute(forName: "content")?.stringValue == "true")
        }

        // Manifest
        struct Item { let path: String; let mediaType: String; let properties: [Substring]; let fallback: String? }
        var items: [String: Item] = [:]
        var mediaTypes: [String: String] = [:]
        let itemEls = packageEl.child("manifest")?.children("item") ?? []
        for el in itemEls {
            guard let id = el.attribute(forName: "id")?.stringValue,
                  let href = el.attribute(forName: "href")?.stringValue,
                  let resolved = BookPath.resolve(href, relativeTo: opfPath) else { continue }
            let path = source.canonicalPath(resolved) ?? resolved
            let type = el.attribute(forName: "media-type")?.stringValue ?? ""
            items[id] = Item(path: path, mediaType: type,
                             properties: (el.attribute(forName: "properties")?.stringValue ?? "").split(separator: " "),
                             fallback: el.attribute(forName: "fallback")?.stringValue)
            mediaTypes[path] = type
        }

        /// Content documents and images (allowed in EPUB 3 fixed-layout spines)
        /// render directly. Anything else follows its manifest fallback chain.
        func renderable(_ start: Item) -> Item? {
            if isImage(start.path, start.mediaType) { return start }
            var seen = Set<String>()
            var cur: Item? = start
            while let item = cur {
                if isContentDocument(item.path, item.mediaType) { return item }
                guard let next = item.fallback, seen.insert(next).inserted else { break }
                cur = items[next]
            }
            return nil
        }

        // Encryption
        let encrypted = parseEncryption(source)
        var fonts: [String: (FontObfuscation, [UInt8])] = [:]
        var drmPaths = Set<String>()
        for (path, algorithm) in encrypted {
            if let kind = FontObfuscation(algorithm: algorithm) {
                if let key = kind.key(uniqueIdentifier: uniqueIdentifier, allIdentifiers: identifiers) { fonts[path] = (kind, key) }
            } else {
                drmPaths.insert(path)
            }
        }

        // Spine
        var spine: [SpineItem] = []
        var declaredIndex: [String: Int] = [:]   // TOC links may target a fallback's original item
        let spineEl = packageEl.child("spine")
        let refs = spineEl?.children("itemref") ?? []
        for ref in refs {
            guard let idref = ref.attribute(forName: "idref")?.stringValue, let declared = items[idref],
                  let item = renderable(declared), let size = source.size(of: item.path) else { continue }
            if drmPaths.contains(item.path) { throw EPUBError.drmProtected }
            let props = (ref.attribute(forName: "properties")?.stringValue ?? "").split(separator: " ")
            let fixed = props.contains("rendition:layout-pre-paginated") ? true
                : props.contains("rendition:layout-reflowable") ? false : globalFixed
            spine.append(SpineItem(path: item.path, mediaType: item.mediaType, byteSize: size, fixedLayout: fixed))
            if declaredIndex[declared.path] == nil { declaredIndex[declared.path] = spine.count - 1 }
        }
        guard !spine.isEmpty else { throw EPUBError.emptySpine }

        // TOC: EPUB 3 nav, then NCX.
        var firstIndex: [String: Int] = [:]
        for (i, s) in spine.enumerated() where firstIndex[s.path] == nil { firstIndex[s.path] = i }
        func spineIndex(_ href: String, base: String) -> (Int, String)? {
            guard let p = BookPath.resolve(href, relativeTo: base) else { return nil }
            let canon = source.canonicalPath(p) ?? p
            guard let i = firstIndex[canon] ?? declaredIndex[canon] else { return nil }
            return (i, BookPath.splitFragment(href).fragment)
        }

        var toc: [TOCEntry] = []
        if let nav = items.values.first(where: { $0.properties.contains("nav") }) {
            toc = parseNav(source, path: nav.path, resolve: spineIndex)
        }
        if toc.isEmpty {
            let ncx = spineEl?.attribute(forName: "toc")?.stringValue.flatMap { items[$0] }
                ?? items.values.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncx = ncx { toc = parseNCX(source, path: ncx.path, resolve: spineIndex) }
        }

        return EPUBBook(title: title, author: author, language: language, packagePath: opfPath,
                        spine: spine, toc: toc, uniqueIdentifier: uniqueIdentifier,
                        mediaTypes: mediaTypes, obfuscatedFonts: fonts)
    }

    // MARK: - Helpers

    private static func isContentDocument(_ path: String, _ mediaType: String) -> Bool {
        if mediaType.contains("html") || mediaType == "image/svg+xml" { return true }
        let ext = (path as NSString).pathExtension.lowercased()
        return ["xhtml", "xht", "html", "htm", "svg"].contains(ext)
    }

    private static func isImage(_ path: String, _ mediaType: String) -> Bool {
        if mediaType.hasPrefix("image/") { return true }
        return ["jpg", "jpeg", "png", "gif", "webp"].contains((path as NSString).pathExtension.lowercased())
    }

    private static func xml(_ source: BookSource, _ path: String, tidy: Bool = false) throws -> XMLDocument {
        let data = try source.read(path)
        // Never resolve external entities: these are untrusted files.
        return try XMLDocument(data: data, options: tidy ? [.documentTidyHTML, .nodeLoadExternalEntitiesNever]
                                                         : [.nodeLoadExternalEntitiesNever])
    }

    private static func locatePackage(_ source: BookSource) throws -> String {
        if let container = try? xml(source, "META-INF/container.xml"),
           let rootfiles = (try? container.nodes(forXPath: "//*[local-name()='rootfile']")) as? [XMLElement] {
            // Prefer the OPF rendition when a container lists several.
            let preferred = rootfiles.first { $0.attribute(forName: "media-type")?.stringValue == "application/oebps-package+xml" }
                ?? rootfiles.first
            if let full = preferred?.attribute(forName: "full-path")?.stringValue,
               let p = BookPath.resolve(full, relativeTo: ""),
               let canon = source.canonicalPath(p) {
                return canon
            }
        }
        // Malformed container: fall back to a conventional location.
        for guess in ["content.opf", "OEBPS/content.opf", "OPS/content.opf", "OPS/package.opf", "EPUB/package.opf"] {
            if let c = source.canonicalPath(guess) { return c }
        }
        throw EPUBError.noPackageDocument
    }

    private static func parseEncryption(_ source: BookSource) -> [String: String] {
        guard source.canonicalPath("META-INF/encryption.xml") != nil,
              let doc = try? xml(source, "META-INF/encryption.xml") else { return [:] }
        var out: [String: String] = [:]
        let blocks = (try? doc.nodes(forXPath: "//*[local-name()='EncryptedData']")) as? [XMLElement] ?? []
        for b in blocks {
            guard let alg = (try? b.nodes(forXPath: ".//*[local-name()='EncryptionMethod']/@Algorithm"))?.first?.stringValue,
                  let uri = (try? b.nodes(forXPath: ".//*[local-name()='CipherReference']/@URI"))?.first?.stringValue,
                  let p = BookPath.resolve(uri, relativeTo: "") else { continue }   // URIs are container-relative
            out[source.canonicalPath(p) ?? p] = alg
        }
        return out
    }

    private static func collapse(_ s: String?) -> String {
        (s ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func parseNav(_ source: BookSource, path: String,
                                 resolve: (String, String) -> (Int, String)?) -> [TOCEntry] {
        guard let doc = (try? xml(source, path)) ?? (try? xml(source, path, tidy: true)) else { return [] }
        let navs = (try? doc.nodes(forXPath: "//*[local-name()='nav']")) as? [XMLElement] ?? []
        let tocNav = navs.first { nav in
            (nav.attributes ?? []).contains { $0.localName == "type" && ($0.stringValue ?? "").split(separator: " ").contains("toc") }
        } ?? navs.first
        guard let nav = tocNav else { return [] }

        var out: [TOCEntry] = []
        func walkList(_ list: XMLElement, depth: Int) {
            for case let li as XMLElement in list.children ?? [] where li.localName == "li" {
                let kids = (li.children ?? []).compactMap { $0 as? XMLElement }
                if let a = kids.first(where: { $0.localName == "a" }),
                   let href = a.attribute(forName: "href")?.stringValue,
                   let (idx, frag) = resolve(href, path) {
                    let title = collapse(a.stringValue)
                    if !title.isEmpty { out.append(TOCEntry(title: title, depth: depth, spineIndex: idx, fragment: frag)) }
                }
                for sub in kids where sub.localName == "ol" || sub.localName == "ul" { walkList(sub, depth: depth + 1) }
            }
        }
        func findLists(_ el: XMLElement) {
            for case let c as XMLElement in el.children ?? [] {
                if c.localName == "ol" || c.localName == "ul" { walkList(c, depth: 0) } else { findLists(c) }
            }
        }
        findLists(nav)
        return out
    }

    private static func parseNCX(_ source: BookSource, path: String,
                                 resolve: (String, String) -> (Int, String)?) -> [TOCEntry] {
        guard let doc = try? xml(source, path),
              let navMap = doc.rootElement()?.child("navMap") else { return [] }
        var out: [TOCEntry] = []
        func walk(_ el: XMLElement, depth: Int) {
            for case let point as XMLElement in el.children ?? [] where point.localName == "navPoint" {
                let label = point.child("navLabel")?.child("text")?.stringValue
                let src = point.child("content")?.attr("src") ?? ""
                if let (idx, frag) = resolve(src, path) {
                    let title = collapse(label)
                    if !title.isEmpty { out.append(TOCEntry(title: title, depth: depth, spineIndex: idx, fragment: frag)) }
                }
                walk(point, depth: depth + 1)
            }
        }
        walk(navMap, depth: 0)
        return out
    }
}

extension XMLElement {
    /// First child element with this local name (namespace-agnostic).
    func child(_ localName: String) -> XMLElement? {
        for case let el as XMLElement in children ?? [] where el.localName == localName { return el }
        return nil
    }

    /// All child elements with this local name (namespace-agnostic).
    func children(_ localName: String) -> [XMLElement] {
        (children ?? []).compactMap { ($0 as? XMLElement).flatMap { $0.localName == localName ? $0 : nil } }
    }

    func attr(_ name: String) -> String? {
        attribute(forName: name)?.stringValue
    }
}
