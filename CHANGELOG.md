# Changelog

## 2.0.0 — Unreleased

Rewrite of the preview engine for calibre-like fidelity and speed.

### Rendering
- Each chapter is rendered **as-is** in its own same-origin iframe instead of being
  merged into one HTML page. Chapters keep their own stylesheets, relative image
  paths resolve correctly, and XHTML is parsed as XML, so **MathML, inline SVG and
  self-closing tags work**. (Supersedes the URL-resolution fix proposed in #3.)
- Embedded fonts obfuscated with the IDPF or Adobe algorithm are de-obfuscated, so
  books show their intended typefaces.
- Fixed-layout books (comics, picture books, and bitmaps directly in the spine)
  render as whole pages scaled to fit the window.
- Vertical writing (Japanese, Chinese) gets a fixed-height page that scrolls sideways;
  the scroll wheel pages through the columns.
- XHTML that isn't well-formed falls back to the forgiving HTML parser instead of
  showing a parser error.
- Wide tables scroll horizontally instead of being clipped.

### Reader
- Table of contents sidebar (EPUB 3 nav or EPUB 2 NCX) that tracks the current section.
- In-book links (footnotes, "see Figure 2.3") jump within the preview; web links open
  in the default browser.
- Text size, page width, and light/sepia/dark themes. In dark mode, images keep their
  original colours on a white backing, so line-art diagrams stay readable.
- Remembers text size, theme and width, and your reading position per book.
- Keyboard: `T` contents, `+`/`−` text size, `D` theme, `W` width, `[`/`]` previous/next section.

### Performance
- Nothing is extracted to disk: book files are served straight from the ZIP through a
  `WKURLSchemeHandler`, on demand.
- Chapters load lazily as they approach the viewport and are unloaded when far away,
  so memory stays flat even on books with 400+ chapters. Unloaded chapters are sized
  from their byte count using a ratio learned from chapters already laid out.
- Parsing a 421-chapter, 3,800-file textbook takes ~60 ms (XPath replaced with
  direct tree traversal); typical novels take ~5 ms.

### Security
- Book JavaScript never runs: chapter iframes are sandboxed without `allow-scripts`, and
  every response carries a Content-Security-Policy that blocks scripts and network access.
- Path traversal (`../`, percent-encoded or via symlinks in package-style EPUBs) is
  rejected; external XML entities are never loaded; resources are capped at 256 MB to
  defuse zip bombs.
- DRM-protected books show a clear message instead of garbage.
- Dropped the `downloads.read-only` and `user-selected.read-only` entitlements, which
  Quick Look doesn't need.

### Project
- `swift test` runs 28 unit tests on the platform-independent core, plus an
  optional corpus test (`EPUB_CORPUS=dir`), all without Xcode signing.
- GitHub Actions CI: unit tests against the 45 IDPF EPUB 3 sample books, viewer JS
  syntax check, and an unsigned app build uploaded as an artifact.
- `scripts/install.sh` builds and installs, signing with your Apple Development
  certificate if you have one and ad hoc otherwise.
- Deployment target lowered to macOS 12 to match the README. Removed the empty
  template test targets.

## 1.0.0 — 2025-08-28
- First public release: Quick Look previews for EPUBs
