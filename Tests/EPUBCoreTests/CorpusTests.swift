import XCTest
@testable import EPUBCore

/// Parses every .epub in $EPUB_CORPUS (CI downloads the IDPF epub3-samples).
/// Skipped when the variable isn't set.
final class CorpusTests: XCTestCase {
    func testWholeCorpusParses() throws {
        guard let dir = ProcessInfo.processInfo.environment["EPUB_CORPUS"] else {
            throw XCTSkip("Set EPUB_CORPUS to a directory of .epub files to run this test.")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".epub") }.sorted()
        XCTAssertFalse(files.isEmpty, "No .epub files in \(dir)")
        for name in files {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            let start = Date()
            do {
                let source = try openBookSource(at: url)
                let book = try EPUBBook.parse(source)
                XCTAssertFalse(book.spine.isEmpty, name)
                // Every spine document must be readable through the server.
                let server = BookServer(source: source, book: book, manifest: Data(), asset: { _ in nil })
                for item in book.spine.prefix(20) {
                    let url = URL(string: "epub-ql://book/" + BookPath.urlEncoded(item.path))!
                    XCTAssertEqual(server.respond(to: url).status, 200, "\(name): \(item.path)")
                }
                for t in book.toc { XCTAssertLessThan(t.spineIndex, book.spine.count, name) }
            } catch {
                XCTFail("\(name): \(error)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, "\(name) took too long to parse")
        }
    }
}
