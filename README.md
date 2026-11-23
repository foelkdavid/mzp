<p align="center">
  <img src="assets/mzp.svg" width="112" alt="mzp icon">
</p>

<h1 align="center">mzp</h1>
<p align="center"><b>manifest ze pdf</b> · a minimal, fast PDF viewer for Wayland</p>

<p align="center">
  <img src="docs/screenshot.png" width="720" alt="mzp showing a document with the page thumbnails sidebar">
</p>

The first page is on screen in a blink, even for big manuals. Scroll, zoom, jump through page thumbnails or the
table of contents, search, select and copy text, and present fullscreen. Pages render in the background, so
scrolling never waits.

**Press `Ctrl + K`** for all keyboard shortcuts, settings and the About page.

## Requirements to run

- Linux x86_64 with a **Wayland** session (no X11 / XWayland)
- OpenGL 3.3 graphics driver (Mesa or your GPU vendor's)
- `libwayland-client`, `libwayland-cursor`, `libwayland-egl`, `libxkbcommon`, `libEGL`: already present on any Wayland desktop

PDFium is bundled and installed with mzp.

Optional, for **scanned PDFs**: [Tesseract](https://github.com/tesseract-ocr/tesseract) plus a language pack
(Void: `tesseract-ocr` and e.g. `tesseract-ocr-eng`). mzp then makes pages without text searchable and selectable,
only when you search or select on them. Ctrl + K → About shows whether it was found.

## Requirements to build

- [C3](https://c3-lang.org) compiler `c3c` **0.8.x**
- a C compiler for linking (`gcc` or `clang`)
- `git`, `python3`

raylib, PDFium and the UI font come with the repository and the [bmu](https://github.com/foelkdavid/bmu) submodule;
nothing else to install.

## Download, build, install

```sh
git clone --recurse-submodules https://github.com/foelkdavid/mzp.git
cd mzp
c3c build install --trust=full
```

This installs `~/.local/bin/mzp`, its PDFium library in `~/.local/lib/mzp/`, a desktop launcher ("Open with" for
PDFs) and the icon (no sudo). Make sure `~/.local/bin` is on your `PATH`, then run `mzp document.pdf`.

```sh
git pull --recurse-submodules && c3c build install --trust=full   # update
c3c build uninstall --trust=full                                   # uninstall
```

## Licenses

PDFium is BSD-3 / Apache-2.0 (third-party notices in [`licenses/pdfium/`](licenses/pdfium/)); the embedded UI font
is SIL OFL 1.1 and raylib is zlib-licensed ([`licenses/`](licenses/)). All are installed with the app.
