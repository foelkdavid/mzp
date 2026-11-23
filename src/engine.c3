module mzp::engine;
import std::thread, std::math, libc;
import bmu::txt;
import pdfium::pdf;
import mzp::ocr;

// The PDF engine: one worker thread owns the PDFium document (PDFium is not thread-safe). The UI thread asks for
// renders, page text and searches through a small locked exchange; results are plain buffers the UI uploads.
// Priority: page text (selection) > renders (UI orders them) > search (one page at a time, so renders interleave).

const int MAX_OUTLINE = 4096;
const int MAX_HITS = 20000;
const int MAX_WANT = 32;
const int MAX_DONE = 12;
const long MAX_RENDER_PIXELS = 24_000_000;
const int SCANNED_BELOW = 16;   // a page with fewer characters counts as a scan (OCR when available)
const float OCR_DPI = 300;

enum State { OPENING, READY, FAILED }
enum Kind { PAGE, THUMB }

struct Want { int page; int width; Kind kind; }
struct Done { int page; int width; int height; Kind kind; char* rgba; }   // UI frees rgba (libc::free)
struct OutlineItem { int page; int depth; char[200] title; }
struct Hit { int page; float x0; float y0; float x1; float y1; }        // fractions of the page, y from the top

// Characters of one page with boxes as fractions of the page (y from the top). UI frees chars / boxes.
struct PageText
{
	int page;
	int count;
	uint* chars;
	float* boxes;            // 4 per char: left, top, right, bottom
}

thread::Mutex mutex;
thread::ConditionVariable wake;
thread::Thread worker;
bool started;
bool quit;
State state = OPENING;
char[256] error;
char[4096] path;

// Written by the worker before READY, read-only afterwards.
int pages;
float* sizes;                // 2 per page: width, height in points
OutlineItem* outline;
int outline_count;
char[256] title;
char[256] author;

Want[MAX_WANT] want;
int want_count;
Done[MAX_DONE] done;
int done_count;
int text_request = -1;
PageText text_done;
bool text_ready;
ushort[256] query;
int query_len;
ulong search_gen;
bool searching;
int search_page;
Hit* hits;                   // MAX_HITS, append-only per search
int hit_count;
int ocr_waiting = -1;         // page the search waits for (being recognized); -1 = none
int text_waiting = -1;        // page whose text (selection) waits for OCR
bool ocr_enabled = true;      // the user's setting (Ctrl+K); OCR runs only when also available

fn bool use_ocr()
{
	mutex.lock();
	bool on = ocr_enabled;
	mutex.unlock();
	return on && ocr::available;
}

<* UI: switch OCR on / off (takes effect for the next search or selection). *>
fn void set_ocr(bool on)
{
	if (!started) { ocr_enabled = on; return; }
	mutex.lock();
	ocr_enabled = on;
	wake.signal();
	mutex.unlock();
}

<* UI: page the search waits for (being recognized) and page whose selection text waits; -1 = none. *>
fn int ocr_status(int* text_wait)
{
	mutex.lock();
	int w = searching ? ocr_waiting : -1;
	*text_wait = text_waiting;
	mutex.unlock();
	return w;
}

pdf::Document doc;

fn void open(String file)
{
	txt::set(&path, file);
	if (!hits) hits = libc::calloc(MAX_HITS, Hit::size);
	if (catch mutex.init()) { state = FAILED; return; }
	if (catch wake.init()) { state = FAILED; return; }
	if (catch worker.create(&work, null)) { state = FAILED; txt::set(&error, "Cannot start the PDF engine"); return; }
	started = true;
}

fn void close()
{
	if (!started) return;
	mutex.lock();
	quit = true;
	wake.signal();
	mutex.unlock();
	worker.join()!!;
	wake.destroy();
	mutex.destroy();
	for (int i = 0; i < done_count; i++) libc::free(done[i].rgba);
	if (text_ready) { libc::free(text_done.chars); libc::free(text_done.boxes); }
	started = false;
}

<* Close the current document (joins the worker and OCR) and open another one. UI thread. *>
fn void reopen(String file)
{
	close();
	ocr::reset();
	libc::free(sizes);
	libc::free(outline);
	sizes = null;
	outline = null;
	doc = null;
	pages = 0;
	outline_count = 0;
	title = {};
	author = {};
	error = {};
	quit = false;
	state = OPENING;
	want_count = 0;
	done_count = 0;
	text_request = -1;
	text_ready = false;
	query_len = 0;
	search_gen++;
	searching = false;
	search_page = 0;
	hit_count = 0;
	ocr_waiting = -1;
	text_waiting = -1;
	open(file);
}

fn State get_state()
{
	if (!started) return state;
	mutex.lock();
	State s = state;
	mutex.unlock();
	return s;
}

<* Replace the render wishes (most important first). Call when the visible set changes, not every frame. *>
fn void set_wants(Want[] list)
{
	mutex.lock();
	want_count = math::min((int)list.len, MAX_WANT);
	for (int i = 0; i < want_count; i++) want[i] = list[i];
	wake.signal();
	mutex.unlock();
}

fn bool take_done(Done* out)
{
	mutex.lock();
	defer mutex.unlock();
	if (!done_count) return false;
	*out = done[0];
	for (int i = 1; i < done_count; i++) done[i - 1] = done[i];
	done_count--;
	wake.signal(); // room for more
	return true;
}

fn void request_text(int page)
{
	mutex.lock();
	text_request = page;
	wake.signal();
	mutex.unlock();
}

fn bool take_text(PageText* out)
{
	mutex.lock();
	defer mutex.unlock();
	if (!text_ready) return false;
	*out = text_done;
	text_ready = false;
	return true;
}

<* Start a search (UTF-8, case-insensitive) from the first page; an empty query stops and clears. *>
fn void search(String utf8)
{
	mutex.lock();
	search_gen++;
	hit_count = 0;
	query_len = 0;
	// UTF-8 -> UTF-16 (BMP is plenty for a search box; other codepoints become surrogate pairs).
	for (usz i = 0; i < utf8.len && query_len < query.len - 3;)
	{
		uint c = utf8[i];
		usz n = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
		if (n > 1) c &= n == 2 ? 0x1F : n == 3 ? 0x0F : 0x07;
		for (usz k = 1; k < n && i + k < utf8.len; k++) c = (c << 6) | (utf8[i + k] & 0x3F);
		i += n;
		if (c >= 0x10000) { c -= 0x10000; query[query_len++] = (ushort)(0xD800 + (c >> 10)); query[query_len++] = (ushort)(0xDC00 + (c & 0x3FF)); }
		else { query[query_len++] = (ushort)c; }
	}
	query[query_len] = 0;
	searching = query_len > 0;
	search_page = 0;
	ocr_waiting = -1;
	wake.signal();
	mutex.unlock();
}

<* Hits so far (hits[0..n) stay valid until the next search()), and whether the search is still running. *>
fn int hit_total(bool* running)
{
	mutex.lock();
	int n = hit_count;
	*running = searching;
	mutex.unlock();
	return n;
}

// ------------------------------------------------------------------------------------------- worker

fn void utf16_to_utf8(ushort* s, usz n, char[] out)
{
	usz k;
	for (usz i = 0; i < n && s[i]; i++)
	{
		uint c = s[i];
		if (c >= 0xD800 && c < 0xDC00 && i + 1 < n) { c = 0x10000 + ((c - 0xD800) << 10) + (s[i + 1] - 0xDC00); i++; }
		if (c < 0x80) { if (k + 1 >= out.len) break; out[k++] = (char)c; }
		else if (c < 0x800) { if (k + 2 >= out.len) break; out[k++] = (char)(0xC0 | c >> 6); out[k++] = (char)(0x80 | (c & 0x3F)); }
		else if (c < 0x10000) { if (k + 3 >= out.len) break; out[k++] = (char)(0xE0 | c >> 12); out[k++] = (char)(0x80 | (c >> 6 & 0x3F)); out[k++] = (char)(0x80 | (c & 0x3F)); }
		else { if (k + 4 >= out.len) break; out[k++] = (char)(0xF0 | c >> 18); out[k++] = (char)(0x80 | (c >> 12 & 0x3F)); out[k++] = (char)(0x80 | (c >> 6 & 0x3F)); out[k++] = (char)(0x80 | (c & 0x3F)); }
	}
	out[k] = 0;
}

fn void read_meta(ZString tag, char[] out)
{
	ushort[512] buf;
	CULong n = pdf::meta_text(doc, tag, &buf, buf.len * 2);
	if (n <= 2) { out[0] = 0; return; }
	utf16_to_utf8(&buf, (usz)n / 2, out);
}

fn void read_outline(pdf::Bookmark parent, int depth)
{
	if (depth > 12) return;
	pdf::Bookmark b = pdf::bookmark_first_child(doc, parent);
	int guard;
	while (b && outline_count < MAX_OUTLINE && guard++ < MAX_OUTLINE)
	{
		OutlineItem* it = &outline[outline_count++];
		ushort[200] buf;
		CULong n = pdf::bookmark_title(b, &buf, buf.len * 2);
		utf16_to_utf8(&buf, math::min((usz)n / 2, (usz)buf.len), &it.title);
		it.depth = depth;
		pdf::Dest d = pdf::bookmark_dest(doc, b);
		if (!d) { pdf::Action a = pdf::bookmark_action(b); if (a) d = pdf::action_dest(doc, a); }
		it.page = d ? pdf::dest_page(doc, d) : -1;
		read_outline(b, depth + 1);
		b = pdf::bookmark_next(doc, b);
	}
}

fn void open_document()
{
	pdf::init_library();
	doc = pdf::load_document(txt::z(&path), null);
	if (!doc)
	{
		CULong e = pdf::last_error();
		mutex.lock();
		txt::set(&error, e == pdf::ERR_PASSWORD ? "This PDF is password protected" : e == 2 ? "Cannot open the file" : "Not a readable PDF");
		state = FAILED;
		mutex.unlock();
		return;
	}
	int n = pdf::page_count(doc);
	float* s = libc::calloc((usz)math::max(n, 1) * 2, float::size);
	for (int i = 0; i < n; i++)
	{
		double w, h;
		if (!pdf::page_size(doc, i, &w, &h)) { w = 612; h = 792; }
		s[i * 2] = (float)w;
		s[i * 2 + 1] = (float)h;
	}
	outline = libc::calloc(MAX_OUTLINE, OutlineItem::size);
	read_outline(null, 0);
	read_meta("Title", &title);
	read_meta("Author", &author);
	mutex.lock();
	sizes = s;
	pages = n;
	state = READY;
	mutex.unlock();
	// OCR (optional): find tesseract off the UI thread; its workers wake us when a page is recognized.
	libc::Stat st;
	libc::stat(txt::z(&path), &st);
	ocr::notify_mutex = &mutex;
	ocr::notify_cv = &wake;
	ocr::detect(txt::view(&path), st.st_size, st.st_mtime, n);
}

<* Render a page in grey at OCR resolution and queue it (once). Engine thread. *>
fn void ocr_submit(int index)
{
	if (!use_ocr() || index < 0 || index >= pages || ocr::is_pending(index) || ocr::get(index)) return;
	float pw = sizes[index * 2];
	float ph = sizes[index * 2 + 1];
	int width = (int)(pw / 72 * OCR_DPI);
	int height = (int)(ph / 72 * OCR_DPI);
	if ((long)width * height > MAX_RENDER_PIXELS) { float k = math::sqrt((float)MAX_RENDER_PIXELS / ((float)width * (float)height)); width = (int)((float)width * k); height = (int)((float)height * k); }
	char* rgba = libc::malloc((usz)width * (usz)height * 4);
	char* gray = libc::malloc((usz)width * (usz)height);
	pdf::Page page = pdf::load_page(doc, index);
	pdf::Bitmap bmp = rgba ? pdf::bitmap_create_ex(width, height, pdf::BITMAP_BGRA, rgba, width * 4) : null;
	if (page && bmp && gray)
	{
		pdf::bitmap_fill_rect(bmp, 0, 0, width, height, 0xFFFFFFFF);
		pdf::render_page(bmp, page, 0, 0, width, height, 0, pdf::RENDER_ANNOT | pdf::RENDER_REVERSE_BYTE_ORDER);
		usz px = (usz)width * (usz)height;
		for (usz i = 0; i < px; i++) gray[i] = (char)(((uint)rgba[i * 4] * 77 + (uint)rgba[i * 4 + 1] * 150 + (uint)rgba[i * 4 + 2] * 29) >> 8);
		if (ocr::submit(index, gray, width, height)) gray = null;
	}
	if (bmp) pdf::bitmap_destroy(bmp);
	if (page) pdf::close_page(page);
	libc::free(rgba);
	libc::free(gray);
}

<* Characters on a page: PDFium's text layer, or null with `scanned` set when it has (almost) none. *>
fn int page_char_count(int index)
{
	pdf::Page page = pdf::load_page(doc, index);
	pdf::TextPage text = page ? pdf::text_load(page) : null;
	int n = text ? pdf::text_count(text) : 0;
	if (text) pdf::text_close(text);
	if (page) pdf::close_page(page);
	return n;
}

fn void deliver_ocr_text(int index, ocr::Result* r)
{
	PageText t = { .page = index };
	if (r && r.count)
	{
		t.chars = libc::malloc((usz)r.count * uint::size);
		t.boxes = libc::malloc((usz)r.count * 4 * float::size);
		if (t.chars && t.boxes)
		{
			libc::memcpy(t.chars, r.chars, (usz)r.count * uint::size);
			libc::memcpy(t.boxes, r.boxes, (usz)r.count * 4 * float::size);
			t.count = r.count;
		}
	}
	mutex.lock();
	if (text_ready) { libc::free(text_done.chars); libc::free(text_done.boxes); }
	text_done = t;
	text_ready = true;
	mutex.unlock();
}

fn uint fold(uint c)
{
	if ((c >= 'A' && c <= 'Z') || (c >= 0xC0 && c <= 0xDE && c != 0xD7)) return c + 32;
	return c;
}

<* Case-insensitive search in recognized text; hits in page order. *>
fn void search_ocr(int index, ocr::Result* r, ulong gen, ushort[] what, int len)
{
	if (!r || len <= 0) return;
	for (int i = 0; i + len <= r.count; i++)
	{
		bool match = true;
		for (int k = 0; k < len && match; k++) match = fold(r.chars[i + k]) == fold(what[k]);
		if (!match) continue;
		Hit h = { index, 1, 1, 0, 0 };
		for (int k = i; k < i + len; k++)
		{
			float* b = &r.boxes[k * 4];
			if (b[2] <= b[0]) continue;
			h.x0 = math::min(h.x0, b[0]); h.y0 = math::min(h.y0, b[1]);
			h.x1 = math::max(h.x1, b[2]); h.y1 = math::max(h.y1, b[3]);
		}
		if (h.x1 <= h.x0) continue;
		mutex.lock();
		bool current = gen == search_gen;
		if (current && hit_count < MAX_HITS) hits[hit_count++] = h;
		mutex.unlock();
		if (!current) return;
		i += len - 1;
	}
}

fn void render(Want w)
{
	if (w.page < 0 || w.page >= pages || w.width <= 0) return;
	float pw = sizes[w.page * 2];
	float ph = sizes[w.page * 2 + 1];
	int width = w.width;
	int height = (int)math::round((float)width * ph / pw);
	if ((long)width * height > MAX_RENDER_PIXELS)
	{
		float k = math::sqrt((float)MAX_RENDER_PIXELS / ((float)width * (float)height));
		width = (int)((float)width * k);
		height = (int)((float)height * k);
	}
	if (width <= 0 || height <= 0) return;
	char* rgba = libc::malloc((usz)width * (usz)height * 4);
	if (!rgba) return;
	pdf::Page page = pdf::load_page(doc, w.page);
	pdf::Bitmap bmp = pdf::bitmap_create_ex(width, height, pdf::BITMAP_BGRA, rgba, width * 4);
	if (!page || !bmp)
	{
		if (bmp) pdf::bitmap_destroy(bmp);
		if (page) pdf::close_page(page);
		libc::free(rgba);
		return;
	}
	pdf::bitmap_fill_rect(bmp, 0, 0, width, height, 0xFFFFFFFF);
	pdf::render_page(bmp, page, 0, 0, width, height, 0, pdf::RENDER_ANNOT | pdf::RENDER_REVERSE_BYTE_ORDER);
	pdf::bitmap_destroy(bmp);
	pdf::close_page(page);
	mutex.lock();
	if (done_count < MAX_DONE) { done[done_count++] = { w.page, width, height, w.kind, rgba }; rgba = null; }
	mutex.unlock();
	libc::free(rgba);
}

fn void extract_text(int index)
{
	if (use_ocr() && page_char_count(index) < SCANNED_BELOW)
	{
		ocr::Result* r = ocr::get(index);
		if (r) { deliver_ocr_text(index, r); return; }
		ocr_submit(index);
		mutex.lock();
		text_waiting = index;
		mutex.unlock();
		return;
	}
	PageText t = { .page = index };
	pdf::Page page = pdf::load_page(doc, index);
	pdf::TextPage text = page ? pdf::text_load(page) : null;
	if (text)
	{
		int n = pdf::text_count(text);
		float pw = sizes[index * 2];
		float ph = sizes[index * 2 + 1];
		t.chars = libc::malloc((usz)math::max(n, 1) * uint::size);
		t.boxes = libc::malloc((usz)math::max(n, 1) * 4 * float::size);
		if (t.chars && t.boxes)
		{
			for (int i = 0; i < n; i++)
			{
				t.chars[i] = pdf::text_unicode(text, i);
				double l, r, b, top;
				if (!pdf::text_char_box(text, i, &l, &r, &b, &top)) { l = r = b = top = 0; }
				t.boxes[i * 4] = (float)(l / pw);
				t.boxes[i * 4 + 1] = (float)(1 - top / ph);
				t.boxes[i * 4 + 2] = (float)(r / pw);
				t.boxes[i * 4 + 3] = (float)(1 - b / ph);
			}
			t.count = n;
		}
		pdf::text_close(text);
	}
	if (page) pdf::close_page(page);
	mutex.lock();
	if (text_ready) { libc::free(text_done.chars); libc::free(text_done.boxes); }
	text_done = t;
	text_ready = true;
	mutex.unlock();
}

<* Search one page. Returns false when the page is a scan still being recognized (the search waits for it, so hits
   stay in page order); meanwhile the next pages are queued for OCR too. *>
fn bool search_page_once(int index, ulong gen, ushort[] what, int len)
{
	if (use_ocr() && page_char_count(index) < SCANNED_BELOW)
	{
		ocr::Result* r = ocr::get(index);
		if (r) { search_ocr(index, r, gen, what, len); return true; }
		ocr_submit(index);
		// Keep the workers busy with the following scanned pages: two renders per call (~0.1 s each), so screen
		// renders still interleave quickly.
		int queued_now;
		for (int p = index + 1; p < pages && p <= index + ocr::workers * 2 && queued_now < 2; p++)
		{
			if (ocr::is_pending(p) || ocr::get(p)) continue;
			if (page_char_count(p) < SCANNED_BELOW) { ocr_submit(p); queued_now++; }
		}
		return false;
	}
	search_one(index, gen, what);
	return true;
}

fn void search_one(int index, ulong gen, ushort[] what)
{
	pdf::Page page = pdf::load_page(doc, index);
	pdf::TextPage text = page ? pdf::text_load(page) : null;
	if (text)
	{
		float pw = sizes[index * 2];
		float ph = sizes[index * 2 + 1];
		pdf::Search s = pdf::find_start(text, what.ptr, 0, 0);
		while (s && pdf::find_next(s))
		{
			int at = pdf::find_index(s);
			int count = pdf::find_count(s);
			Hit h = { index, 1, 1, 0, 0 };
			for (int i = at; i < at + count; i++)
			{
				double l, r, b, top;
				if (!pdf::text_char_box(text, i, &l, &r, &b, &top) || r <= l) continue;
				h.x0 = math::min(h.x0, (float)(l / pw));
				h.y0 = math::min(h.y0, (float)(1 - top / ph));
				h.x1 = math::max(h.x1, (float)(r / pw));
				h.y1 = math::max(h.y1, (float)(1 - b / ph));
			}
			if (h.x1 <= h.x0) continue;
			mutex.lock();
			bool current = gen == search_gen;
			if (current && hit_count < MAX_HITS) hits[hit_count++] = h;
			mutex.unlock();
			if (!current) break;
		}
		if (s) pdf::find_close(s);
		pdf::text_close(text);
	}
	if (page) pdf::close_page(page);
}

fn int work(void* arg)
{
	// Temp memory for this thread (only the main thread has one implicitly).
	@pool_init(mem, 256 * 1024) { run(); };
	return 0;
}

fn void run()
{
	open_document();
	while (true)
	{
		mutex.lock();
		while (!quit && state == READY && text_request < 0 && (want_count == 0 || done_count >= MAX_DONE)
			&& (!searching || (ocr_waiting >= 0 && ocr::is_pending(ocr_waiting)))
			&& !(text_waiting >= 0 && !ocr::is_pending(text_waiting))) wake.wait(&mutex);
		if (quit || state != READY) { mutex.unlock(); break; }
		int text_ocr = -1;
		if (text_waiting >= 0 && !ocr::is_pending(text_waiting)) { text_ocr = text_waiting; text_waiting = -1; }
		int text_page = text_request;
		text_request = -1;
		Want w = { .page = -1 };
		if (text_page < 0 && want_count > 0 && done_count < MAX_DONE)
		{
			w = want[0];
			for (int i = 1; i < want_count; i++) want[i - 1] = want[i];
			want_count--;
		}
		int sp = -1;
		ulong gen = search_gen;
		ushort[256] what;
		int len = query_len;
		if (text_page < 0 && w.page < 0 && searching && !(ocr_waiting >= 0 && ocr::is_pending(ocr_waiting)))
		{
			sp = search_page;
			what = query;
		}
		mutex.unlock();
		if (text_ocr >= 0) deliver_ocr_text(text_ocr, ocr::get(text_ocr));
		if (text_page >= 0 && text_page < pages) { extract_text(text_page); }
		else if (w.page >= 0) { render(w); }
		else if (sp >= 0 && sp < pages)
		{
			bool finished = search_page_once(sp, gen, &what, len);
			mutex.lock();
			if (gen == search_gen)
			{
				if (finished) { ocr_waiting = -1; search_page = sp + 1; if (search_page >= pages) searching = false; }
				else { ocr_waiting = sp; }
			}
			mutex.unlock();
		}
	}
	ocr::close();
	if (doc) pdf::close_document(doc);
	pdf::destroy_library();
}
