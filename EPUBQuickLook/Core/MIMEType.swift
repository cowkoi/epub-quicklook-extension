//
//  MIMEType.swift
//  EPUBQuickLook
//

import Foundation

enum MIMEType {
    /// Content type for a resource. The manifest's declared type wins, except that
    /// `.xhtml` files are always served as XHTML: they must go through the XML
    /// parser for MathML, SVG and self-closing tags to work.
    static func forPath(_ path: String, declared: String?) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "xhtml" || ext == "xht" { return "application/xhtml+xml" }
        if let d = declared?.trimmingCharacters(in: .whitespaces), !d.isEmpty, d.contains("/") { return d }
        return byExtension[ext] ?? "application/octet-stream"
    }

    static let byExtension: [String: String] = [
        "html": "text/html", "htm": "text/html",
        "xml": "application/xml", "opf": "application/oebps-package+xml",
        "ncx": "application/x-dtbncx+xml", "smil": "application/smil+xml",
        "css": "text/css", "js": "text/javascript", "json": "application/json", "txt": "text/plain",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff",
        "avif": "image/avif",
        "ttf": "font/ttf", "otf": "font/otf", "woff": "font/woff", "woff2": "font/woff2",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "ogg": "audio/ogg", "opus": "audio/ogg",
        "wav": "audio/wav", "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm", "mov": "video/quicktime",
    ]
}
