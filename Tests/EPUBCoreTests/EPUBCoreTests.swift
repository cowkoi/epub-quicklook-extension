import XCTest
import CryptoKit
@testable import EPUBCore

final class BookPathTests: XCTestCase {
    func testResolvesRelativeToContainingFile() {
        XCTAssertEqual(BookPath.resolve("../images/a.png", relativeTo: "OPS/xhtml/ch1.xhtml"), "OPS/images/a.png")
        XCTAssertEqual(BookPath.resolve("b.xhtml#frag", relativeTo: "OPS/xhtml/ch1.xhtml"), "OPS/xhtml/b.xhtml")
        XCTAssertEqual(BookPath.resolve("./x/./y.css?v=2", relativeTo: "a.opf"), "x/y.css")
        XCTAssertEqual(BookPath.resolve("/OPS/root.css", relativeTo: "OPS/xhtml/ch1.xhtml"), "OPS/root.css")
    }

    func testPercentDecoding() {
        XCTAssertEqual(BookPath.resolve("ch%201.xhtml", relativeTo: "OPS/x.opf"), "OPS/ch 1.xhtml")
        XCTAssertEqual(BookPath.splitFragment("a.xhtml#sec%201").fragment, "sec 1")
    }

    func testRejectsEscapesAndExternalURLs() {
        XCTAssertNil(BookPath.resolve("../../etc/passwd", relativeTo: "OPS/ch.xhtml"))
        XCTAssertNil(BookPath.resolve("%2E%2E/%2E%2E/x", relativeTo: "OPS/ch.xhtml"))
        XCTAssertNil(BookPath.resolve("https://example.com/a.png", relativeTo: "OPS/ch.xhtml"))
        XCTAssertNil(BookPath.resolve("mailto:a@b.c", relativeTo: "OPS/ch.xhtml"))
        XCTAssertNil(BookPath.resolve("data:image/png;base64,AAAA", relativeTo: "OPS/ch.xhtml"))
        XCTAssertNil(BookPath.resolve("#only-fragment", relativeTo: "OPS/ch.xhtml"))
        XCTAssertNil(BookPath.normalize("a/../../b"))
        XCTAssertEqual(BookPath.normalize("a\\b\\..\\c"), "a/c")
    }

    func testURLEncoding() {
        XCTAssertEqual(BookPath.urlEncoded("OPS/ch 1#x?.xhtml"), "OPS/ch%201%23x%3F.xhtml")
        XCTAssertEqual(BookPath.urlEncoded("OPS/100%.xhtml"), "OPS/100%25.xhtml")
    }
}

final class EPUBBookTests: XCTestCase {
    func testParsesStandardBook() throws {
        let f = try EPUBFixture.standard()
        let book = try EPUBBook.parse(try openBookSource(at: f.url))
        XCTAssertEqual(book.title, "Test Book")
        XCTAssertEqual(book.author, "A. Author")
        XCTAssertEqual(book.language, "en")
        XCTAssertEqual(book.packagePath, "OPS/package.opf")
        XCTAssertEqual(book.spine.map(\.path), ["OPS/text/ch 1.xhtml", "OPS/text/ch2.xhtml"])
        XCTAssertGreaterThan(book.spine[0].byteSize, 0)
        XCTAssertEqual(book.mediaTypes["OPS/styles/book.css"], "text/css")
    }

    func testNavTOCPreferredOverNCXAndUsesTocNav() throws {
        let f = try EPUBFixture.standard()
        let toc = try EPUBBook.parse(try openBookSource(at: f.url)).toc
        XCTAssertEqual(toc.map(\.title), ["Chapter One", "Section 1.1", "Chapter Two"])
        XCTAssertEqual(toc.map(\.depth), [0, 1, 1])
        XCTAssertEqual(toc.map(\.spineIndex), [0, 0, 1])
        XCTAssertEqual(toc[1].fragment, "sec-1.1")
    }

    func testFallsBackToNCX() throws {
        let f = try EPUBFixture.standard(nav: false)
        let toc = try EPUBBook.parse(try openBookSource(at: f.url)).toc
        XCTAssertEqual(toc.map(\.title), ["NCX One", "NCX 1.1", "NCX Two"])
        XCTAssertEqual(toc.map(\.depth), [0, 1, 0])
    }

    func testMissingContainerFallsBackToConventionalOPF() throws {
        let f = try EPUBFixture()
        try f.add("OEBPS/content.opf", """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata/>
        <manifest><item id="a" href="a.html" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="a"/></spine></package>
        """)
        try f.add("OEBPS/a.html", "<html><body>hi</body></html>")
        let book = try EPUBBook.parse(try openBookSource(at: f.url))
        XCTAssertEqual(book.spine.map(\.path), ["OEBPS/a.html"])
    }

    func testCaseInsensitiveFallback() throws {
        let f = try EPUBFixture()
        try f.container("content.opf")
        try f.add("content.opf", """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata/>
        <manifest><item id="a" href="Text/Chapter.XHTML" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="a"/></spine></package>
        """)
        try f.add("text/chapter.xhtml", EPUBFixture.xhtml("x"))
        let book = try EPUBBook.parse(try openBookSource(at: f.url))
        XCTAssertEqual(book.spine.map(\.path), ["text/chapter.xhtml"])
    }

    func testNonZipFileThrowsNotAnArchive() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).epub")
        try Data("not a zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try openBookSource(at: url)) { XCTAssertEqual($0 as? BookSourceError, .notAnArchive) }
    }

    func testEmptySpineThrows() throws {
        let f = try EPUBFixture()
        try f.container("content.opf")
        try f.add("content.opf", #"<package xmlns="http://www.idpf.org/2007/opf"><metadata/><manifest/><spine/></package>"#)
        XCTAssertThrowsError(try EPUBBook.parse(try openBookSource(at: f.url))) {
            XCTAssertEqual($0 as? EPUBError, .emptySpine)
        }
    }

    func testFixedLayoutDetection() throws {
        let f = try EPUBFixture()
        try f.container("p.opf")
        try f.add("p.opf", """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata><meta property="rendition:layout">pre-paginated</meta></metadata>
          <manifest>
            <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
            <item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="a"/><itemref idref="b" properties="rendition:layout-reflowable"/></spine>
        </package>
        """)
        try f.add("a.xhtml", EPUBFixture.xhtml("a"))
        try f.add("b.xhtml", EPUBFixture.xhtml("b"))
        let book = try EPUBBook.parse(try openBookSource(at: f.url))
        XCTAssertEqual(book.spine.map(\.fixedLayout), [true, false])
    }

    func testImagesInSpineRenderDirectlyAndForeignTypesUseFallback() throws {
        let f = try EPUBFixture()
        try f.container("p.opf")
        try f.add("p.opf", """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata/>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="img" href="p1.jpg" media-type="image/jpeg" fallback="nav"/>
            <item id="odd" href="p2.foo" media-type="application/x-foo" fallback="alt"/>
            <item id="alt" href="p2.xhtml" media-type="application/xhtml+xml"/>
            <item id="loop" href="p3.foo" media-type="application/x-foo" fallback="loop"/>
          </manifest>
          <spine><itemref idref="img"/><itemref idref="odd"/><itemref idref="loop"/></spine>
        </package>
        """)
        for p in ["nav.xhtml", "p2.xhtml"] { try f.add(p, EPUBFixture.xhtml("x")) }
        try f.add("p1.jpg", Data([0xFF, 0xD8]))
        try f.add("p2.foo", "?")
        try f.add("p3.foo", "?")
        let book = try EPUBBook.parse(try openBookSource(at: f.url))
        XCTAssertEqual(book.spine.map(\.path), ["p1.jpg", "p2.xhtml"])
    }

    func testDRMProtectedSpineIsReported() throws {
        let f = try EPUBFixture.standard()
        try f.add("META-INF/encryption.xml", """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <enc:CipherData><enc:CipherReference URI="OPS/text/ch2.xhtml"/></enc:CipherData></enc:EncryptedData>
        </encryption>
        """)
        XCTAssertThrowsError(try EPUBBook.parse(try openBookSource(at: f.url))) {
            XCTAssertEqual($0 as? EPUBError, .drmProtected)
        }
    }

    func testIgnoresExternalEntities() throws {
        // An XXE payload must not be expanded (or fetched).
        let f = try EPUBFixture()
        try f.container("p.opf")
        try f.add("p.opf", """
        <?xml version="1.0"?>
        <!DOCTYPE package [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>&xxe;</dc:title></metadata>
        <manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/></spine></package>
        """)
        try f.add("a.xhtml", EPUBFixture.xhtml("a"))
        let book = try? EPUBBook.parse(try openBookSource(at: f.url))
        XCTAssertFalse(book?.title.contains("root:") ?? false)
    }
}

final class FontObfuscationTests: XCTestCase {
    let font = Data((0..<3000).map { UInt8($0 % 251) })

    func testIDPFKeyIsSHA1OfIdentifierWithoutWhitespace() {
        let key = FontObfuscation.idpf.key(uniqueIdentifier: " urn:isbn:\t978 0\n", allIdentifiers: [])
        XCTAssertEqual(key, Array(Insecure.SHA1.hash(data: Data("urn:isbn:9780".utf8))))
    }

    func testAdobeKeyFromUUID() {
        let key = FontObfuscation.adobe.key(uniqueIdentifier: "isbn", allIdentifiers: ["urn:uuid:00112233-4455-6677-8899-AABBCCDDEEFF"])
        XCTAssertEqual(key, [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    func testRoundTripOnlyTouchesHeader() {
        for kind in [FontObfuscation.idpf, .adobe] {
            let key = kind.key(uniqueIdentifier: "urn:uuid:00112233-4455-6677-8899-aabbccddeeff", allIdentifiers: [])!
            var d = font
            kind.apply(to: &d, key: key)
            XCTAssertNotEqual(d.prefix(kind.headerLength), font.prefix(kind.headerLength))
            XCTAssertEqual(d.suffix(from: kind.headerLength), font.suffix(from: kind.headerLength))
            kind.apply(to: &d, key: key)
            XCTAssertEqual(d, font)
        }
    }

    func testServerDeobfuscatesFonts() throws {
        let f = try EPUBFixture.standard()
        let uid = "urn:uuid:12345678-1234-1234-1234-123456789abc"
        var mangled = font
        FontObfuscation.idpf.apply(to: &mangled, key: FontObfuscation.idpf.key(uniqueIdentifier: uid, allIdentifiers: [])!)
        try f.add("OPS/fonts/f.otf", mangled)
        try f.add("META-INF/encryption.xml", """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <enc:CipherData><enc:CipherReference URI="OPS/fonts/f.otf"/></enc:CipherData></enc:EncryptedData>
        </encryption>
        """)
        let source = try openBookSource(at: f.url)
        let book = try EPUBBook.parse(source)
        let server = BookServer(source: source, book: book, manifest: Data(), asset: { _ in nil })
        let r = server.respond(to: URL(string: "epub-ql://book/OPS/fonts/f.otf")!)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.mimeType, "font/otf")
        XCTAssertEqual(r.data, font)
    }
}

final class BookServerTests: XCTestCase {
    func makeServer() throws -> (BookServer, EPUBFixture) {
        let f = try EPUBFixture.standard()
        let source = try openBookSource(at: f.url)
        let book = try EPUBBook.parse(source)
        let server = BookServer(source: source, book: book, manifest: Data("{}".utf8),
                                asset: { $0 == "viewer.js" ? Data("js".utf8) : nil })
        return (server, f)
    }

    func testServesChapterAsXHTMLWithRestrictiveCSP() throws {
        let (server, f) = try makeServer(); _ = f
        let r = server.respond(to: URL(string: "epub-ql://book/OPS/text/ch%201.xhtml")!)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.mimeType, "application/xhtml+xml")
        XCTAssertTrue(r.headers["Content-Security-Policy"]?.contains("script-src 'none'") ?? false)
        XCTAssertTrue(String(decoding: r.data, as: UTF8.self).contains("<h1>One</h1>"))
    }

    func testServesViewerAssetsAndManifest() throws {
        let (server, f) = try makeServer(); _ = f
        XCTAssertEqual(server.respond(to: URL(string: "epub-ql://book/.ql/viewer.js")!).data, Data("js".utf8))
        XCTAssertEqual(server.respond(to: URL(string: "epub-ql://book/.ql/book.json")!).data, Data("{}".utf8))
        XCTAssertEqual(server.respond(to: URL(string: "epub-ql://book/.ql/secret.txt")!).status, 404)
    }

    func testRejectsTraversalOtherHostsAndMissingFiles() throws {
        let (server, f) = try makeServer(); _ = f
        XCTAssertEqual(server.respond(to: URL(string: "epub-ql://book/../../etc/passwd")!).status, 404)
        XCTAssertEqual(server.respond(to: URL(string: "epub-ql://book/OPS/%2E%2E/%2E%2E/x")!).status, 404)
        XCTAssertEqual(server.respond(to: URL(string: "epub-ql://other/OPS/text/ch2.xhtml")!).status, 404)
        XCTAssertEqual(server.respond(to: URL(string: "file:///etc/passwd")!).status, 404)
        XCTAssertEqual(server.respond(to: URL(string: "epub-ql://book/OPS/nope.xhtml")!).status, 404)
    }

    func testManifestEncodesSpineHrefsAndClampsPosition() throws {
        let f = try EPUBFixture.standard()
        let book = try EPUBBook.parse(try openBookSource(at: f.url))
        let m = ViewerManifest(book: book, prefs: [:], position: .init(i: 99, frac: 0.5))
        XCTAssertEqual(m.spine.map(\.href), ["OPS/text/ch%201.xhtml", "OPS/text/ch2.xhtml"])
        XCTAssertNil(m.position)
        XCTAssertEqual(ViewerManifest(book: book, prefs: [:], position: .init(i: 1, frac: 0.5)).position?.i, 1)
    }
}

final class DirectorySourceTests: XCTestCase {
    func testReadsPackageBundleAndBlocksSymlinkEscape() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pkg-\(UUID().uuidString).epub")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("OPS/A.xhtml"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("OPS/escape"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))

        let source = try openBookSource(at: root)
        XCTAssertEqual(try source.read("OPS/A.xhtml"), Data("hello".utf8))
        XCTAssertEqual(source.canonicalPath("ops/a.xhtml"), "OPS/A.xhtml")
        XCTAssertThrowsError(try source.read("OPS/escape"))
        XCTAssertThrowsError(try source.read("../etc/hosts"))
    }
}

final class MIMETypeTests: XCTestCase {
    func testXHTMLAlwaysServedAsXML() {
        XCTAssertEqual(MIMEType.forPath("a.xhtml", declared: "text/html"), "application/xhtml+xml")
        XCTAssertEqual(MIMEType.forPath("a.html", declared: "application/xhtml+xml"), "application/xhtml+xml")
        XCTAssertEqual(MIMEType.forPath("a.html", declared: nil), "text/html")
        XCTAssertEqual(MIMEType.forPath("a.woff2", declared: ""), "font/woff2")
        XCTAssertEqual(MIMEType.forPath("a.unknown", declared: nil), "application/octet-stream")
    }
}

final class ReaderStoreTests: XCTestCase {
    var defaults: UserDefaults!
    var store: ReaderStore!

    override func setUp() {
        defaults = UserDefaults(suiteName: "ReaderStoreTests-\(UUID().uuidString)")
        store = ReaderStore(defaults: defaults)
    }

    func testPrefsAreValidated() {
        store.savePrefs(["font": "130", "theme": "dark", "wide": "2", "evil": "x"])
        XCTAssertEqual(store.prefs, ["font": "130", "theme": "dark", "wide": "2"])
        store.savePrefs(["font": "9999", "theme": "<script>", "wide": "-1"])
        XCTAssertEqual(store.prefs, [:])
    }

    func testPositionRoundTripAndClamping() {
        let key = ReaderStore.bookKey(for: URL(fileURLWithPath: "/tmp/a.epub"))
        XCTAssertEqual(key.count, 24)
        XCTAssertNil(store.position(for: key))
        store.savePosition(key, index: 12, fraction: 1.7)
        XCTAssertEqual(store.position(for: key), .init(i: 12, frac: 1))
        store.savePosition(key, index: -1, fraction: 0.5)          // ignored
        store.savePosition(key, index: 3, fraction: .nan)          // ignored
        XCTAssertEqual(store.position(for: key)?.i, 12)
    }

    func testOldPositionsAreEvicted() {
        for n in 0..<305 { store.savePosition("k\(n)", index: n, fraction: 0) }
        XCTAssertNotNil(store.position(for: "k304"))
        let all = defaults.dictionary(forKey: "positions") ?? [:]
        XCTAssertLessThanOrEqual(all.count, 300)
    }
}
