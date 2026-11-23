module mzp::engine;
import std::thread, std::math, libc;
import bmu::txt;
import pdfium::pdf;

// The PDF engine: one worker thread owns the PDFium document (PDFium is not thread-safe). The UI thread asks for
// renders, page text and searches through a small locked exchange; results are plain buffers the UI uploads.
// Priority: page text (selection) > renders (UI orders them) > search (one page at a time, so renders interleave).

const int MAX_OUTLINE = 4096;
const int MAX_HITS = 20000;
const int MAX_WANT = 32;
const int MAX_DONE = 12;
const long MAX_RENDER_PIXELS = 24_000_000;

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

pdf::Document doc;

fn void open(String file)
{
	txt::set(&path, file);
	hits = libc::calloc(MAX_HITS, Hit::size);
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
	open_document();
	while (true)
	{
		mutex.lock();
		while (!quit && state == READY && text_request < 0 && (want_count == 0 || done_count >= MAX_DONE) && !searching) wake.wait(&mutex);
		if (quit || state != READY) { mutex.unlock(); break; }
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
		if (text_page < 0 && w.page < 0 && searching)
		{
			sp = search_page++;
			if (search_page >= pages) searching = false;
			what = query;
		}
		mutex.unlock();
		if (text_page >= 0 && text_page < pages) { extract_text(text_page); }
		else if (w.page >= 0) { render(w); }
		else if (sp >= 0 && sp < pages) { search_one(sp, gen, &what); }
	}
	if (doc) pdf::close_document(doc);
	pdf::destroy_library();
	return 0;
}
