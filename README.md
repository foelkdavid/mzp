# mzp — manifest ze pdf

A minimal, fast PDF viewer for Wayland, built on [bmu](https://github.com/foelkdavid/bmu) (C3 + raylib) and
[PDFium](https://pdfium.googlesource.com/pdfium/) (via [pdfium-binaries](https://github.com/bblanchon/pdfium-binaries)).

```sh
mzp document.pdf
```

| Key | Action |
|---|---|
| Wheel, Up / Down | scroll |
| Page Up / Down, Space | one screen |
| Left / Right, Home / End | previous / next page, first / last |
| Ctrl + / - / 0, Ctrl + wheel | zoom (0 = fit width) |
| Ctrl + S | sidebar: Pages (thumbnails) / Contents (table of contents) |
| Ctrl + F | search; Enter / Shift + Enter or ‹ › for next / previous hit |
| Drag on a page, Ctrl + C | select text, copy it |
| F5 or Present (sidebar) | presenter view: fullscreen, Right / Down / Space next, Left / Up previous, Escape leaves |
| Ctrl + K | shortcuts and About |
| Ctrl + Shift + / - / 0 | interface zoom |
| q | quit |

Fast by design: the document is parsed on a worker thread while the window opens (first page on screen in
~160 ms, also for a 477-page manual); pages render at the screen's pixel size only when visible, with the old
texture scaled meanwhile; thumbnails render only for visible sidebar rows; search runs page by page in the
background (all 477 pages in ~0.5 s) without ever blocking scrolling. The sidebar state and the interface zoom are
remembered in `$XDG_CONFIG_HOME/mzp/settings`.

## Scanned PDFs (optional OCR)

If [Tesseract](https://github.com/tesseract-ocr/tesseract) is installed (`tesseract` or Void's `tesseract-ocr`, plus
a language pack such as `tesseract-ocr-eng` / `tesseract-ocr-deu`), search and text selection also work on pages
without a text layer. Only such pages are recognized, only when you search or select on them, in parallel
background processes (half the CPU cores, up to 4); scrolling never waits. Results are cached in
`$XDG_CACHE_HOME/mzp/` (default `~/.cache/mzp/`), so reopening a document is instant. All installed text
languages are used (Fraktur only if nothing else is installed). Ctrl+K → General switches OCR off; Ctrl+K → About
shows whether Tesseract was found and which languages it has. Nothing is bundled.

## Build and install

Needs `c3c` 0.8.x and a Wayland session.

```sh
git clone --recurse-submodules git@github.com:foelkdavid/mzp.git
cd mzp && c3c build install --trust=full     # ~/.local/bin/mzp, ~/.local/lib/mzp/libpdfium.so, PDF launcher
git pull --recurse-submodules && c3c build install --trust=full    # update
c3c build uninstall --trust=full
```

PDFium is a C3 library like raylib: `lib/pdfium.c3l/` holds the binding (`pdfium.c3i`), the manifest and the
prebuilt `libpdfium.so` (shared only; the binary finds it through its rpath, in the repo or next to the install).
`dev/tools/fetch-pdfium.sh` re-downloads the pinned release and checks its hash.

## Licenses

PDFium is BSD-3 / Apache-2.0; its third-party notices (FreeType, ICU, libjpeg-turbo, …) are in `licenses/pdfium/`.
The embedded UI font is OFL 1.1 and raylib is zlib-licensed (`licenses/`). All are installed with the binary.
