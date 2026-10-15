//
//  EPUBQuickLookHostApp.swift
//  EPUBQuickLookHost
//
//  Created by Arytek on 27/8/2025.
//
//  The host app exists to carry the Quick Look extension. Opening it once
//  registers the extension; the window explains how to use and enable it.
//

import SwiftUI
import AppKit

@main
struct EPUBQuickViewHostApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("EPUB Quick Look").font(.title2.bold())
                Text(version).foregroundStyle(.secondary)
            }
            Text("The extension is installed. Select an .epub in Finder and press Space to preview it.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("In the preview").font(.headline)
                Group {
                    Text("T  contents  ·  + / −  text size  ·  D  theme  ·  W  page width")
                    Text("[ / ]  previous / next section")
                }
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            }

            Text("No preview? Make sure EPUBQuickLook is enabled in System Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Extension Settings…", action: openSettings)
                Spacer()
                Button("Done") { NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func openSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}
