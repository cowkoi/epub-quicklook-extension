//
//  BookSource.swift
//  EPUBQuickLook
//
//  Random access to the files of an EPUB without extracting it to disk.
//  Zipped books are read entry-by-entry straight from the archive; Apple's
//  directory-style "package" EPUBs are read from the bundle with a containment check.
//

import Foundation
import ZIPFoundation

enum BookSourceError: LocalizedError, Equatable {
    case notFound(String)
    case tooLarge(String)
    case unreadable(String)
    case notAnArchive

    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "Missing file in book: \(p)"
        case .tooLarge(let p): return "File in book is too large to preview: \(p)"
        case .unreadable(let p): return "Couldn't read \(p) from the book."
        case .notAnArchive: return "This file isn't a valid EPUB: it couldn't be opened as a ZIP archive."
        }
    }
}

protocol BookSource: AnyObject {
    /// The stored path for `path`, falling back to a case-insensitive match
    /// (many EPUBs are authored on case-insensitive file systems).
    func canonicalPath(_ path: String) -> String?
    /// Uncompressed size in bytes, if the file exists.
    func size(of path: String) -> Int?
    /// Full contents. Thread-safe.
    func read(_ path: String) throws -> Data
}

/// Upper bound for a single resource; protects the extension from zip bombs.
let maxResourceBytes = 256 * 1024 * 1024

func openBookSource(at url: URL) throws -> BookSource {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
        throw BookSourceError.unreadable(url.lastPathComponent)
    }
    return isDir.boolValue ? try DirectoryBookSource(root: url) : try ZipBookSource(url: url)
}

// MARK: - Zip

final class ZipBookSource: BookSource {
    private let archive: Archive
    private let entries: [String: Entry]
    private let folded: [String: String]
    private let lock = NSLock()   // ZIPFoundation's Archive shares one file handle

    init(url: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw BookSourceError.notAnArchive
        }
        var entries: [String: Entry] = [:]
        var folded: [String: String] = [:]
        for entry in archive where entry.type == .file {
            guard let path = BookPath.normalize(entry.path) else { continue }  // drops "../" entries
            if entries[path] == nil { entries[path] = entry }
            let key = path.lowercased()
            if folded[key] == nil { folded[key] = path }
        }
        self.archive = archive
        self.entries = entries
        self.folded = folded
    }

    func canonicalPath(_ path: String) -> String? {
        entries[path] != nil ? path : folded[path.lowercased()]
    }

    func size(of path: String) -> Int? {
        canonicalPath(path).flatMap { entries[$0] }.map { Int(clamping: $0.uncompressedSize) }
    }

    func read(_ path: String) throws -> Data {
        guard let key = canonicalPath(path), let entry = entries[key] else { throw BookSourceError.notFound(path) }
        guard entry.uncompressedSize <= UInt64(maxResourceBytes) else { throw BookSourceError.tooLarge(path) }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        lock.lock(); defer { lock.unlock() }
        do {
            _ = try archive.extract(entry) { chunk in
                // The declared size can lie; enforce the cap on actual output too.
                guard data.count + chunk.count <= maxResourceBytes else { throw BookSourceError.tooLarge(path) }
                data.append(chunk)
            }
        } catch let e as BookSourceError {
            throw e
        } catch {
            throw BookSourceError.unreadable(path)
        }
        return data
    }
}

// MARK: - Directory ("package" EPUB bundles)

final class DirectoryBookSource: BookSource {
    private let root: URL
    private let rootPath: String
    private var folded: [String: String]?
    private let lock = NSLock()

    init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.rootPath = self.root.path.hasSuffix("/") ? self.root.path : self.root.path + "/"
    }

    /// Returns the on-disk URL for `path` only if it stays inside the bundle after
    /// resolving symlinks.
    private func contained(_ path: String) -> URL? {
        guard let norm = BookPath.normalize(path) else { return nil }
        let url = root.appendingPathComponent(norm).resolvingSymlinksInPath()
        guard url.path.hasPrefix(rootPath) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return url
    }

    /// Always returns the *stored* spelling, even on case-insensitive volumes, so
    /// two references that differ only in case map to the same spine item.
    func canonicalPath(_ path: String) -> String? {
        guard let norm = BookPath.normalize(path) else { return nil }
        let (exact, folded) = index()
        if exact.contains(norm) { return norm }
        return folded[norm.lowercased()]
    }

    private var exactPaths: Set<String>?

    private func index() -> (Set<String>, [String: String]) {
        lock.lock(); defer { lock.unlock() }
        if let e = exactPaths, let f = folded { return (e, f) }
        var exact = Set<String>()
        var f: [String: String] = [:]
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let u as URL in e {
                guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let p = u.standardizedFileURL.path
                guard p.hasPrefix(rootPath) else { continue }
                let rel = String(p.dropFirst(rootPath.count))
                exact.insert(rel)
                if f[rel.lowercased()] == nil { f[rel.lowercased()] = rel }
            }
        }
        exactPaths = exact
        folded = f
        return (exact, f)
    }

    func size(of path: String) -> Int? {
        guard let c = canonicalPath(path), let url = contained(c) else { return nil }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
    }

    func read(_ path: String) throws -> Data {
        guard let c = canonicalPath(path), let url = contained(c) else { throw BookSourceError.notFound(path) }
        if let s = size(of: c), s > maxResourceBytes { throw BookSourceError.tooLarge(path) }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
