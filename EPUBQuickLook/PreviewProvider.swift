//
//  PreviewProvider.swift
//  EPUBQuickLook
//

import AppKit
import WebKit
import QuickLookUI
import os.log

final class PreviewProvider: NSViewController, QLPreviewingController, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var bookKey = ""
    private let log = OSLog(subsystem: "EPUBQuickLook", category: "Preview")

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        preferredContentSize = NSSize(width: 960, height: 1150)
        bookKey = ReaderStore.bookKey(for: url)
        let store = ReaderStore.shared
        let key = bookKey

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let didStart = url.startAccessingSecurityScopedResource()
            // The zip handle stays open for the preview's lifetime; the security
            // scope only needs to cover opening it.
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }

            let server: BookServer
            do {
                let source = try openBookSource(at: url)
                let book = try EPUBBook.parse(source)
                let manifest = ViewerManifest(book: book, prefs: store.prefs, position: store.position(for: key))
                server = BookServer(source: source, book: book, manifest: try JSONEncoder().encode(manifest), asset: Self.asset)
            } catch {
                os_log("EPUB error: %{public}@", log: self?.log ?? .default, type: .error, String(describing: error))
                let manifest = ViewerManifest(error: error.localizedDescription, title: url.deletingPathExtension().lastPathComponent)
                server = BookServer(source: nil, book: nil, manifest: (try? JSONEncoder().encode(manifest)) ?? Data(), asset: Self.asset)
            }
            DispatchQueue.main.async {
                self?.present(server)
                handler(nil)
            }
        }
    }

    private static func asset(_ name: String) -> Data? {
        let ns = name as NSString
        guard let url = Bundle(for: PreviewProvider.self).url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    private func present(_ server: BookServer) {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(BookSchemeHandler(server: server), forURLScheme: BookServer.scheme)
        cfg.websiteDataStore = .nonPersistent()
        cfg.userContentController.add(WeakScriptMessageHandler(self), name: "reader")

        let wv = WKWebView(frame: view.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        view.addSubview(wv)
        webView = wv
        wv.load(URLRequest(url: BookServer.entryURL))
    }

    // Only our own origin may load; activated external links go to the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased()
        if scheme == BookServer.scheme || scheme == "about" {
            decisionHandler(.allow)
        } else {
            if action.navigationType == .linkActivated, let url = action.request.url { openExternal(url) }
            decisionHandler(.cancel)
        }
    }

    private func openExternal(_ url: URL) {
        guard let s = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(s) else { return }
        NSWorkspace.shared.open(url)
    }

    // Messages from viewer.js: {type: "prefs" | "position" | "open", ...}
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == BookServer.scheme,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "prefs":
            if let p = body["prefs"] as? [String: Any] { ReaderStore.shared.savePrefs(p) }
        case "position":
            if let i = (body["i"] as? NSNumber)?.intValue, let f = (body["frac"] as? NSNumber)?.doubleValue {
                ReaderStore.shared.savePosition(bookKey, index: i, fraction: f)
            }
        case "open":
            if let s = body["url"] as? String, let url = URL(string: s) { openExternal(url) }
        default:
            break
        }
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
    }
}

/// WKUserContentController retains its handlers; this breaks the retain cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}
