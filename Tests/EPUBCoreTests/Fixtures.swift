import XCTest
import ZIPFoundation
@testable import EPUBCore

/// Builds small EPUB archives in a temp directory for tests.
final class EPUBFixture {
    let url: URL
    private let archive: Archive

    init(name: String = UUID().uuidString) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).epub")
        try? FileManager.default.removeItem(at: url)
        archive = try Archive(url: url, accessMode: .create)
        try add("mimetype", "application/epub+zip", compressed: false)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func add(_ path: String, _ text: String, compressed: Bool = true) throws {
        try add(path, Data(text.utf8), compressed: compressed)
    }

    func add(_ path: String, _ data: Data, compressed: Bool = true) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: compressed ? .deflate : .none) { pos, size in
            data.subdata(in: Int(pos)..<Int(pos) + size)
        }
    }

    func container(_ opfPath: String) throws {
        try add("META-INF/container.xml", """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
    }

    static func xhtml(_ body: String, head: String = "") -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title>\(head)</head><body>\(body)</body></html>
        """
    }

    /// A typical EPUB 3 book: OPF in OPS/, chapters in OPS/text/, images in OPS/images/.
    static func standard(nav: Bool = true, ncx: Bool = true) throws -> EPUBFixture {
        let f = try EPUBFixture()
        try f.container("OPS/package.opf")
        try f.add("OPS/package.opf", """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier>
            <dc:title>  Test Book </dc:title>
            <dc:creator>A. Author</dc:creator>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            \(nav ? #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"# : "")
            \(ncx ? #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"# : "")
            <item id="c1" href="text/ch%201.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="styles/book.css" media-type="text/css"/>
            <item id="img" href="images/fig.png" media-type="image/png"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="c1"/>
            <itemref idref="c2"/>
          </spine>
        </package>
        """)
        if nav {
            try f.add("OPS/nav.xhtml", xhtml("""
            <nav xmlns:epub="http://www.idpf.org/2007/ops" epub:type="landmarks"><ol><li><a href="text/ch2.xhtml">Wrong</a></li></ol></nav>
            <nav xmlns:epub="http://www.idpf.org/2007/ops" epub:type="toc"><ol>
              <li><a href="text/ch%201.xhtml">Chapter
                One</a>
                <ol><li><a href="text/ch%201.xhtml#sec-1.1">Section 1.1</a></li></ol></li>
              <li><span>Part heading</span><ol><li><a href="text/ch2.xhtml">Chapter Two</a></li></ol></li>
            </ol></nav>
            """))
        }
        if ncx {
            try f.add("OPS/toc.ncx", """
            <?xml version="1.0"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
              <navPoint id="n1"><navLabel><text>NCX One</text></navLabel><content src="text/ch%201.xhtml"/>
                <navPoint id="n2"><navLabel><text>NCX 1.1</text></navLabel><content src="text/ch%201.xhtml#sec-1.1"/></navPoint>
              </navPoint>
              <navPoint id="n3"><navLabel><text>NCX Two</text></navLabel><content src="text/ch2.xhtml"/></navPoint>
            </navMap></ncx>
            """)
        }
        try f.add("OPS/text/ch 1.xhtml", xhtml(#"<h1>One</h1><img src="../images/fig.png"/><p id="sec-1.1">x</p>"#,
                                               head: #"<link rel="stylesheet" href="../styles/book.css"/>"#))
        try f.add("OPS/text/ch2.xhtml", xhtml("<h1>Two</h1>"))
        try f.add("OPS/styles/book.css", "h1 { color: teal }")
        try f.add("OPS/images/fig.png", Data([0x89, 0x50, 0x4E, 0x47]))
        return f
    }
}
