//
//  BookSchemeHandler.swift
//  EPUBQuickLook
//

import Foundation
import WebKit

/// Adapts `BookServer` to WebKit. Reads happen on a background queue; tasks
/// WebKit has already stopped are never answered (doing so raises an exception).
final class BookSchemeHandler: NSObject, WKURLSchemeHandler {
    private let server: BookServer
    private let queue = DispatchQueue(label: "EPUBQuickLook.io", qos: .userInitiated, attributes: .concurrent)
    private var live = Set<ObjectIdentifier>()      // main-thread only

    init(server: BookServer) {
        self.server = server
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        live.insert(id)
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL)); live.remove(id); return
        }
        queue.async { [server] in
            let r = server.respond(to: url)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.live.remove(id) != nil else { return }
                var headers = r.headers
                let textual = r.mimeType.hasPrefix("text/")
                headers["Content-Type"] = textual ? "\(r.mimeType); charset=utf-8" : r.mimeType
                headers["Content-Length"] = String(r.data.count)
                let response = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: headers)!
                task.didReceive(response)
                task.didReceive(r.data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }
}
