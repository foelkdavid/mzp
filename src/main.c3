module mzp;
import std::math, std::core::string, std::core::dstring, std::io, libc;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::sys;
import mzp::engine, mzp::ocr;

// mzp - manifest ze pdf. Continuous page view, Ctrl+S sidebar (Pages / Contents), Ctrl+F search, text selection +
// Ctrl+C, presenter mode (F5). All PDF work happens on the engine thread; this file only lays out and draws.

const float GAP = 16;
const float MARGIN = 24;
const float BAR_W = 250;
const float THUMB_W = 150;
const float THUMB_ROW = 230;
const float TOC_ROW = 30;
const int TEXTURES = 24;
const int TEXTS = 8;
const int ID_SEARCH = 1;
const Color PAGE_WHITE = { 255, 255, 255, 255 };

struct Tex { int page; engine::Kind kind; int width; rl::RLTexture2D tex; ulong used; }

// View.
float scroll;                 // logical px from the top of the document
float zoom = 1;               // on top of "fit width"
float k_px;                   // points -> logical px for the current layout
float* offs;                  // page tops (logical px), pages + 1
float laid_w = -1;
float laid_zoom = -1;
float doc_h;
float max_pw = 1;
int cur_page;
Tex[TEXTURES] texs;
ulong clock;
engine::Want[engine::MAX_WANT] wanted;
int wanted_count;

// Sidebar.
bool bar;
int bar_tab;                  // 0 = pages, 1 = contents
float bar_scroll;

// Search.
bool searching;
char[256] search_text;
double search_due;
int cur_hit = -1;

// Selection (one page at a time).
engine::PageText[TEXTS] texts;
int sel_page = -1;
float sel_ax;
float sel_ay;
float sel_bx;
float sel_by;
bool selecting;
int sel_a = -1;
int sel_b = -1;

// Presenter.
bool presenting;
int present_page;

// Ctrl+K and remembered settings.
bool settings_open;
int settings_tab;
float help_scroll;
char[1024] config_file;
int ui_percent;
bool prefs_dirty;
bool ocr_on = true;           // read scanned pages with tesseract (when available)
char[4096] file_path;

ui::Shortcut[*] help_rows = {
	{ "READ", "", true },
	{ "Wheel / Up / Down", "Scroll", false },
	{ "Page Up / Down, Space", "One screen up / down", false },
	{ "Left / Right", "Previous / next page", false },
	{ "Home / End", "First / last page", false },
	{ "Ctrl + / - / 0, Ctrl + wheel", "Zoom (0 = fit width)", false },
	{ "TEXT", "", true },
	{ "Drag on a page", "Select text", false },
	{ "Ctrl + C", "Copy the selection", false },
	{ "Ctrl + F", "Search; Enter / Shift + Enter for next / previous", false },
	{ "SIDEBAR", "", true },
	{ "Ctrl + S", "Show / hide (Pages, Contents)", false },
	{ "PRESENT", "", true },
	{ "F5 / Present (sidebar)", "Presenter view (fullscreen)", false },
	{ "Right / Down / Space", "Next page", false },
	{ "Left / Up", "Previous page", false },
	{ "Escape", "Leave presenter view", false },
	{ "APP", "", true },
	{ "Ctrl + Shift + / - / 0", "Zoom the interface", false },
	{ "Ctrl + K", "This dialog", false },
	{ "q", "Quit", false },
};

// ------------------------------------------------------------------------------------------- settings

fn void prefs_load() => @pool()
{
	String base = sys::env("XDG_CONFIG_HOME");
	if (!base.starts_with("/")) base = txt::join(sys::home(), ".config");
	txt::set(&config_file, txt::join(base, "mzp/settings"));
	String? data = sys::read_temp(txt::view(&config_file));
	if (catch data) return;
	if (data.len > 4096) return;
	foreach (line : data.tsplit("\n"))
	{
		if (line.starts_with("bar=")) bar = line == "bar=1";
		if (line.starts_with("bar_tab=")) bar_tab = line == "bar_tab=1" ? 1 : 0;
		if (line.starts_with("ocr=")) ocr_on = line != "ocr=0";
		if (line.starts_with("ui_scale="))
		{
			if (try v = line[9..].to_int()) if (v == 0 || (v >= 75 && v <= 300)) ui_percent = v;
		}
	}
}

fn void prefs_save() => @pool()
{
	if (!prefs_dirty || txt::empty(&config_file)) return;
	String file = txt::view(&config_file);
	if (!sys::mkdirs(txt::dirname(file))) return;
	String tmp = txt::join(txt::dirname(file), "settings.tmp");
	if (sys::write_file(tmp, string::tformat("bar=%d\nbar_tab=%d\nui_scale=%d\nocr=%d\n", bar ? 1 : 0, bar_tab, ui_percent, ocr_on ? 1 : 0))) sys::move(tmp, file);
}

// ------------------------------------------------------------------------------------------- layout

fn float view_x() => bar && !presenting ? BAR_W : 0;

<* Page tops for "fit width" times zoom; recomputed only when the width or zoom changes (O(pages)). *>
fn void layout(float view_w)
{
	if (view_w == laid_w && zoom == laid_zoom && offs) return;
	float old_k = k_px;
	float anchor = k_px > 0 ? scroll / k_px : 0; // keep the same document point at the top
	laid_w = view_w;
	laid_zoom = zoom;
	if (!offs) offs = libc::calloc((usz)engine::pages + 1, float::size);
	max_pw = 1;
	for (int i = 0; i < engine::pages; i++) max_pw = math::max(max_pw, engine::sizes[i * 2]);
	k_px = math::max(0.05f, (view_w - 2 * MARGIN) * zoom / max_pw);
	float y = GAP;
	for (int i = 0; i < engine::pages; i++)
	{
		offs[i] = y;
		y += engine::sizes[i * 2 + 1] * k_px + GAP;
	}
	offs[engine::pages] = y;
	doc_h = y;
	if (old_k > 0) scroll = anchor * k_px;
}

fn int page_at(float y)
{
	int lo = 0;
	int hi = engine::pages - 1;
	while (lo < hi)
	{
		int mid = (lo + hi + 1) / 2;
		if (offs[mid] <= y) { lo = mid; } else { hi = mid - 1; }
	}
	return math::max(0, lo);
}

fn Rect page_rect(int i, float view_w)
{
	float w = engine::sizes[i * 2] * k_px;
	float h = engine::sizes[i * 2 + 1] * k_px;
	return { view_x() + (view_w - w) / 2, offs[i] - scroll, w, h };
}

fn void go_page(int i)
{
	if (!engine::pages) return;
	i = math::clamp(i, 0, engine::pages - 1);
	scroll = offs[i] - GAP;
	cur_page = i;
}

fn void start_presenting()
{
	presenting = true;
	present_page = cur_page;
	if (!rl::is_window_fullscreen()) rl::toggle_fullscreen();
}

// ------------------------------------------------------------------------------------------- textures

fn Tex* find_tex(int page, engine::Kind kind)
{
	Tex* best;
	foreach (&t : texs)
	{
		if (t.page != page || t.kind != kind || !t.tex.id) continue;
		if (!best || t.width > best.width) best = t;
	}
	return best;
}

fn void upload(engine::Done* d)
{
	// Replace an older texture of the same page/kind, else the least recently used one.
	Tex* slot;
	foreach (&t : texs) if (t.tex.id && t.page == d.page && t.kind == d.kind) { slot = t; break; }
	if (!slot)
	{
		slot = &texs[0];
		foreach (&t : texs)
		{
			if (!t.tex.id) { slot = t; break; }
			if (t.used < slot.used) slot = t;
		}
	}
	if (slot.tex.id) rl::unload_texture(slot.tex);
	rl::RLImage img = { .data = d.rgba, .width = d.width, .height = d.height, .mipmaps = 1, .format = rl::RLPixelFormat.UNCOMPRESSED_R8G8B8A8 };
	slot.tex = rl::load_texture_from_image(img);
	slot.tex.set_filter(rl::RLTextureFilter.BILINEAR);
	slot.page = d.page;
	slot.kind = d.kind;
	slot.width = d.width;
	slot.used = ++clock;
	libc::free(d.rgba);
}

fn void add_want(engine::Want[] list, int* n, int page, int width, engine::Kind kind)
{
	if (*n >= list.len || page < 0 || page >= engine::pages || width < 8) return;
	Tex* t = find_tex(page, kind);
	// Good enough: within 10% of the wanted resolution (zooming shows the old texture scaled until then).
	if (t && math::abs(t.width - width) * 10 <= width) { t.used = ++clock; return; }
	for (int i = 0; i < *n; i++) if (list[i].page == page && list[i].kind == kind) return;
	list[(*n)++] = { page, width, kind };
}

<* Send the wish list only when it changed (no per-frame locking work in the engine). *>
fn void send_wants(engine::Want[] list, int n)
{
	bool same = n == wanted_count;
	for (int i = 0; same && i < n; i++) same = list[i].page == wanted[i].page && list[i].width == wanted[i].width && list[i].kind == wanted[i].kind;
	if (same) return;
	for (int i = 0; i < n; i++) wanted[i] = list[i];
	wanted_count = n;
	engine::set_wants(list[:n]);
}

// ------------------------------------------------------------------------------------------- text / selection

fn engine::PageText* text_of(int page)
{
	foreach (&t : texts) if (t.chars && t.page == page) return t;
	return null;
}

fn void poll_text()
{
	engine::PageText got;
	if (!engine::take_text(&got)) return;
	if (!got.chars) return;
	// Oldest slot out (slot 0), newest in at the end.
	if (texts[0].chars) { libc::free(texts[0].chars); libc::free(texts[0].boxes); }
	for (int i = 1; i < TEXTS; i++) texts[i - 1] = texts[i];
	texts[TEXTS - 1] = got;
}

<* Character nearest to (x, y) (fractions of the page): a box containing it, else the closest box centre. *>
fn int char_at(engine::PageText* t, float x, float y)
{
	int best = -1;
	float best_d = 1e9;
	for (int i = 0; i < t.count; i++)
	{
		float* b = &t.boxes[i * 4];
		if (b[2] <= b[0]) continue;
		if (x >= b[0] && x <= b[2] && y >= b[1] && y <= b[3]) return i;
		float cx = (b[0] + b[2]) / 2;
		float cy = (b[1] + b[3]) / 2;
		float d = (cx - x) * (cx - x) + (cy - y) * (cy - y) * 4; // prefer the same line
		if (d < best_d) { best_d = d; best = i; }
	}
	return best;
}

fn void update_selection()
{
	engine::PageText* t = text_of(sel_page);
	if (!t) return;
	sel_a = char_at(t, sel_ax, sel_ay);
	sel_b = char_at(t, sel_bx, sel_by);
}

fn void copy_selection() => @pool()
{
	engine::PageText* t = text_of(sel_page);
	if (!t || sel_a < 0 || sel_b < 0) return;
	int a = math::min(sel_a, sel_b);
	int b = math::max(sel_a, sel_b);
	DString out;
	out.tinit();
	for (int i = a; i <= b && i < t.count; i++)
	{
		uint c = t.chars[i];
		if (c == '\r' || c == 0 || c == 0xFFFE) continue;
		char[4] u;
		usz n;
		if (c < 0x80) { u[0] = (char)c; n = 1; }
		else if (c < 0x800) { u[0] = (char)(0xC0 | c >> 6); u[1] = (char)(0x80 | (c & 0x3F)); n = 2; }
		else if (c < 0x10000) { u[0] = (char)(0xE0 | c >> 12); u[1] = (char)(0x80 | (c >> 6 & 0x3F)); u[2] = (char)(0x80 | (c & 0x3F)); n = 3; }
		else { u[0] = (char)(0xF0 | c >> 18); u[1] = (char)(0x80 | (c >> 12 & 0x3F)); u[2] = (char)(0x80 | (c >> 6 & 0x3F)); u[3] = (char)(0x80 | (c & 0x3F)); n = 4; }
		out.append((String)u[:n]);
	}
	if (!out.len()) return;
	rl::set_clipboard_text(out.str_view().zstr_tcopy());
	ui::toast(string::tformat("Copied %d characters", b - a + 1));
}

// ------------------------------------------------------------------------------------------- search

<* First hit index of `page` (hits are in page order). *>
fn int first_hit(int page, int n)
{
	int lo = 0;
	int hi = n;
	while (lo < hi)
	{
		int mid = (lo + hi) / 2;
		if (engine::hits[mid].page < page) { lo = mid + 1; } else { hi = mid; }
	}
	return lo;
}

fn void show_hit(int i, float view_h)
{
	cur_hit = i;
	engine::Hit h = engine::hits[i];
	float y = offs[h.page] + h.y0 * engine::sizes[h.page * 2 + 1] * k_px;
	if (y < scroll + 40 || y > scroll + view_h - 80) scroll = y - view_h / 3;
}

fn void step_hit(int dir, float view_h)
{
	bool running;
	int n = engine::hit_total(&running);
	if (!n) return;
	if (cur_hit < 0) { show_hit(math::min(first_hit(cur_page, n), n - 1), view_h); return; }
	show_hit(((cur_hit + dir) % n + n) % n, view_h);
}

fn void close_search()
{
	searching = false;
	txt::set(&search_text, "");
	engine::search("");
	cur_hit = -1;
	ui::unfocus();
}

// ------------------------------------------------------------------------------------------- main

fn int main(String[] args)
{
	String file = "";
	for (usz i = 1; i < args.len; i++)
	{
		switch (args[i])
		{
			case "--shot": case "--frames": case "--scale": i++;
			case "--help": case "-h":
				io::printn("Usage: mzp FILE.pdf\nScroll / Up / Down, Page Up / Down, Left / Right: pages. Ctrl +/-/0: zoom. Ctrl+S: sidebar (Pages, Contents).\nCtrl+F: search (Enter / Shift+Enter). Drag: select text, Ctrl+C: copy. F5: presenter view. Ctrl+K: shortcuts and About.\nCtrl+Shift +/-/0: interface zoom. q: quit.");
				return 0;
			default: file = args[i];
		}
	}
	if (!file.len) { io::eprintn("mzp: give a PDF file (mzp FILE.pdf)"); return 2; }
	@pool() { sys::realpath(&file_path, file); };
	// The document is parsed on the engine thread while the window is created.
	prefs_load();
	engine::set_ocr(ocr_on);
	engine::open(txt::view(&file_path));
	defer prefs_save();
	ui::open("mzp", 1100, 900, 360, 300, (float)ui_percent / 100);
	ui::zoom_shift_only = true;
	ui::clear_color = ui::BG_HARD;
	defer ui::close();
	defer engine::close();
	defer foreach (&t : texs) if (t.tex.id) rl::unload_texture(t.tex);
	ui::app_args(args);
	@pool() { rl::set_window_title(string::tformat("%s - mzp", txt::basename(txt::view(&file_path))).zstr_tcopy()); };
	while (ui::running()) frame();
	return 0;
}

fn void frame() => @pool()
{
	ui::frame_begin(settings_open);
	float w = ui::sw();
	float h = ui::sh();
	if (ui::zoom_changed) { ui_percent = (int)math::round(ui::scale * 100); prefs_dirty = true; }
	if (ui::ctrl_down() && ui::letter('k')) { settings_open = !settings_open; if (settings_open && settings_tab == 1) collect_about(); ui::top = settings_open ? 1 : 0; }
	engine::State st = engine::get_state();
	engine::Done d;
	while (engine::take_done(&d)) upload(&d);
	poll_text();
	if (st != READY)
	{
		String msg = st == OPENING ? "Opening…" : txt::view(&engine::error);
		ui::text(msg, 24, 24, 18, st == FAILED ? ui::RED : ui::GRAY);
		if (ui::letter('q')) ui::quit = true;
		settings_draw();
		ui::frame_end();
		return;
	}
	if (presenting) { present(w, h); settings_draw(); ui::frame_end(); return; }

	float vx = view_x();
	float view_w = w - vx;
	layout(view_w);
	bool keys = ui::top == 0 && ui::focus < 0;
	if (keys)
	{
		if (ui::ctrl_down() && ui::letter('s')) { bar = !bar; prefs_dirty = true; }
		if (ui::ctrl_down() && ui::letter('f')) { searching = true; ui::focus_on(ID_SEARCH, &search_text); }
		if (ui::ctrl_down() && ui::letter('c')) copy_selection();
		if (!ui::ctrl_down())
		{
			if (ui::repeat(rl::RLKeyboardKey.DOWN)) scroll += 60;
			if (ui::repeat(rl::RLKeyboardKey.UP)) scroll -= 60;
			if (ui::repeat(rl::RLKeyboardKey.PAGE_DOWN) || ui::repeat(rl::RLKeyboardKey.SPACE)) scroll += h - 60;
			if (ui::repeat(rl::RLKeyboardKey.PAGE_UP)) scroll -= h - 60;
			if (ui::repeat(rl::RLKeyboardKey.RIGHT)) go_page(cur_page + 1);
			if (ui::repeat(rl::RLKeyboardKey.LEFT)) go_page(scroll > offs[cur_page] - GAP + 2 ? cur_page : cur_page - 1);
			if (rl::is_key_pressed(rl::RLKeyboardKey.HOME)) go_page(0);
			if (rl::is_key_pressed(rl::RLKeyboardKey.END)) go_page(engine::pages - 1);
			if (rl::is_key_pressed(rl::RLKeyboardKey.F5)) start_presenting();
			if (rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) { sel_page = -1; if (searching) close_search(); }
			if (ui::letter('q')) ui::quit = true;
		}
	}
	// Zoom: Ctrl +/-/0 around the view centre, Ctrl + wheel around the pointer.
	rl::RLVector2 mouse = rl::get_mouse_position();
	if (ui::top == 0)
	{
		float factor = 1;
		float at = h / 2;
		if (ui::ctrl_down() && !ui::shift_down() && ui::focus < 0)
		{
			int step = ui::zoom_step();
			if (step > 0) factor = 1.2f;
			if (step < 0) factor = 1 / 1.2f;
			if (rl::is_key_pressed(rl::RLKeyboardKey.ZERO)) factor = 1 / zoom;
		}
		float wheel = rl::get_mouse_wheel_move();
		if (wheel != 0 && mouse[0] >= vx)
		{
			if (ui::ctrl_down()) { factor = wheel > 0 ? 1.1f : 1 / 1.1f; at = mouse[1]; }
			else { scroll -= wheel * 90; }
		}
		if (factor != 1)
		{
			float doc_y = (scroll + at) / k_px;
			zoom = math::clamp(zoom * factor, 0.2f, 8.0f);
			layout(view_w);
			scroll = doc_y * k_px - at;
		}
	}
	scroll = math::clamp(scroll, 0.0f, math::max(0.0f, doc_h - h));
	cur_page = page_at(scroll + h / 3);

	// Wishes: the current page first, then the rest of the visible ones, then one ahead / behind; thumbnails last.
	int first = page_at(scroll);
	int last = page_at(scroll + h);
	engine::Want[engine::MAX_WANT] list;
	int n;
	float sc = ui::scale;
	add_want(&list, &n, cur_page, (int)(engine::sizes[cur_page * 2] * k_px * sc), PAGE);
	for (int i = first; i <= last; i++) add_want(&list, &n, i, (int)(engine::sizes[i * 2] * k_px * sc), PAGE);
	if (last + 1 < engine::pages) add_want(&list, &n, last + 1, (int)(engine::sizes[(last + 1) * 2] * k_px * sc), PAGE);
	if (first > 0) add_want(&list, &n, first - 1, (int)(engine::sizes[(first - 1) * 2] * k_px * sc), PAGE);

	// Pages.
	ui::begin_clip({ vx, 0, view_w, h });
	bool running;
	int hits = searching ? engine::hit_total(&running) : 0;
	for (int i = first; i <= last; i++)
	{
		Rect r = page_rect(i, view_w);
		Tex* t = find_tex(i, PAGE);
		ui::panel(r, PAGE_WHITE);
		if (t) { t.used = ++clock; rl::draw_texture_pro(t.tex, { 0, 0, (float)t.tex.width, (float)t.tex.height }, r, { 0, 0 }, 0, rl::WHITE); }
		for (int k = first_hit(i, hits); k < hits && engine::hits[k].page == i; k++)
		{
			engine::Hit hh = engine::hits[k];
			Rect hr = { r.x + hh.x0 * r.width - 1, r.y + hh.y0 * r.height - 1, (hh.x1 - hh.x0) * r.width + 2, (hh.y1 - hh.y0) * r.height + 2 };
			ui::panel(hr, k == cur_hit ? (Color){ 254, 128, 25, 150 } : (Color){ 250, 189, 47, 110 });
		}
		if (i == sel_page && sel_a >= 0 && sel_b >= 0)
		{
			engine::PageText* tx = text_of(i);
			if (tx)
			{
				for (int c = math::min(sel_a, sel_b); c <= math::max(sel_a, sel_b) && c < tx.count; c++)
				{
					float* b = &tx.boxes[c * 4];
					if (b[2] <= b[0]) continue;
					ui::panel({ r.x + b[0] * r.width, r.y + b[1] * r.height, (b[2] - b[0]) * r.width, (b[3] - b[1]) * r.height }, (Color){ 69, 133, 136, 110 });
				}
			}
		}
		if (ui::top == 0 && ui::clicked(r))
		{
			ui::unfocus();
			sel_page = i;
			sel_ax = (mouse[0] - r.x) / r.width;
			sel_ay = (mouse[1] - r.y) / r.height;
			sel_bx = sel_ax;
			sel_by = sel_ay;
			sel_a = -1;
			sel_b = -1;
			selecting = true;
			if (!text_of(i)) engine::request_text(i);
		}
	}
	ui::end_clip();
	if (selecting)
	{
		if (!rl::is_mouse_button_down(rl::RLMouseButton.LEFT)) selecting = false;
		Rect r = page_rect(sel_page, view_w);
		sel_bx = math::clamp((mouse[0] - r.x) / r.width, 0.0f, 1.0f);
		sel_by = math::clamp((mouse[1] - r.y) / r.height, 0.0f, 1.0f);
		if (mouse[1] < 20) scroll -= 12;
		if (mouse[1] > h - 20) scroll += 12;
		update_selection();
		// A click without a drag selects nothing.
		if (!selecting && math::abs(sel_bx - sel_ax) * r.width < 3 && math::abs(sel_by - sel_ay) * r.height < 3) { sel_page = -1; sel_a = -1; sel_b = -1; }
	}
	else if (sel_page >= 0 && sel_a < 0 && text_of(sel_page)) { update_selection(); }

	if (bar) draw_bar(h, &list, &n);
	send_wants(&list, n);

	// Page badge and the two buttons (or the search bar) at the top right.
	String pos = string::tformat("%d / %d", cur_page + 1, engine::pages);
	int text_wait;
	engine::ocr_status(&text_wait);
	if (text_wait >= 0) pos = string::tformat("recognizing p. %d… · %s", text_wait + 1, pos);
	float pw = ui::text_w(pos, 13) + 16;
	ui::panel({ w - pw - 10, h - 32, pw, 24 }, ui::BG, 4);
	ui::text(pos, w - pw - 2, h - 27, 13, ui::FG4);
	// No buttons on the page: search is Ctrl+F, presenter is F5 or the sidebar's Present button.
	if (searching) draw_search(w, h);
	settings_draw();
	ui::frame_end();
}

fn void draw_search(float w, float h) => @pool()
{
	Rect box = { w - 470, 8, 460, 44 };
	ui::panel(box, ui::BG, 6);
	ui::outline(box, ui::BG2, 6);
	bool submitted;
	if (ui::input(ID_SEARCH, { box.x + 6, box.y + 4, 200, 36 }, &search_text, "Search", &submitted, ui::I_SEARCH))
	{
		search_due = ui::now + 0.2;
		cur_hit = -1;
	}
	if (search_due > 0 && ui::now >= search_due) { search_due = 0; engine::search(txt::view(&search_text)); }
	bool running;
	int n = engine::hit_total(&running);
	// Jump to the first hit at or after the current page as soon as one exists.
	if (cur_hit < 0 && n > 0 && search_due == 0) step_hit(1, h);
	if (submitted) step_hit(ui::shift_down() ? -1 : 1, h);
	int text_wait;
	int scan = engine::ocr_status(&text_wait);
	String count = txt::empty(&search_text) ? "" : n == 0 ? (running || search_due > 0 ? "…" : "no results") : string::tformat("%d / %d%s", cur_hit + 1, n, running ? "+" : "");
	if (scan >= 0) count = string::tformat("%s%sreading scan p. %d", count, count.len ? " · " : "", scan + 1);
	ui::text_fit(count, box.x + 214, box.y + 14, 140, 13, n || scan >= 0 ? ui::FG4 : ui::GRAY);
	if (scan >= 0 && ui::hover({ box.x + 210, box.y, 146, box.height })) ui::tooltip(count);
	if (ui::icon_button({ box.x + 358, box.y + 6, 30, 32 }, ui::I_LEFT, ui::FG4, "Previous (Shift+Enter)")) step_hit(-1, h);
	if (ui::icon_button({ box.x + 390, box.y + 6, 30, 32 }, ui::I_RIGHT, ui::FG4, "Next (Enter)")) step_hit(1, h);
	if (ui::icon_button({ box.x + 422, box.y + 6, 30, 32 }, ui::I_TIMES, ui::FG4, "Close (Escape)")) close_search();
	if (ui::focused(ID_SEARCH) && rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) close_search();
}

<* Sidebar: Pages (thumbnails rendered for the visible rows only) or Contents (outline). *>
fn void draw_bar(float h, engine::Want[] list, int* n) => @pool()
{
	ui::panel({ 0, 0, BAR_W, h }, ui::BG);
	ui::panel({ BAR_W - 1, 0, 1, h }, ui::BG2);
	if (ui::button({ 8, 8, BAR_W / 2 - 12, 32 }, "Pages", bar_tab == 0 ? PRIMARY : NORMAL)) { bar_tab = 0; bar_scroll = 0; prefs_dirty = true; }
	if (ui::button({ BAR_W / 2 + 4, 8, BAR_W / 2 - 12, 32 }, "Contents", bar_tab == 1 ? PRIMARY : NORMAL)) { bar_tab = 1; bar_scroll = 0; prefs_dirty = true; }
	Rect area = { 0, 48, BAR_W - 1, h - 48 - 52 };
	ui::panel({ 0, h - 52, BAR_W - 1, 52 }, ui::BG);
	ui::hline(0, h - 52, BAR_W - 1, ui::BG2);
	if (ui::button({ 8, h - 44, BAR_W - 17, 36 }, "Present (F5)", NORMAL, ui::I_PLAY)) start_presenting();
	if (bar_tab == 0)
	{
		float content = (float)engine::pages * THUMB_ROW;
		bar_scroll = ui::scroll_wheel(area, bar_scroll, content);
		ui::begin_clip(area);
		int first = math::max(0, (int)(bar_scroll / THUMB_ROW));
		int end = math::min(engine::pages, first + (int)(area.height / THUMB_ROW) + 2);
		for (int i = first; i < end; i++)
		{
			Rect cell = { 10, area.y + (float)i * THUMB_ROW - bar_scroll + 4, BAR_W - 21, THUMB_ROW - 8 };
			if (i == cur_page) { ui::panel(cell, ui::BG2, 6); }
			else if (ui::hover(cell)) { ui::panel(cell, ui::BG1, 6); }
			float pw = engine::sizes[i * 2];
			float ph = engine::sizes[i * 2 + 1];
			float k = math::min(THUMB_W / pw, (THUMB_ROW - 40) / ph);
			Rect pr = { cell.x + (cell.width - pw * k) / 2, cell.y + 8, pw * k, ph * k };
			ui::panel(pr, PAGE_WHITE);
			Tex* t = find_tex(i, THUMB);
			if (!t) t = find_tex(i, PAGE); // a full page texture scales down fine
			if (t) { t.used = ++clock; rl::draw_texture_pro(t.tex, { 0, 0, (float)t.tex.width, (float)t.tex.height }, pr, { 0, 0 }, 0, rl::WHITE); }
			else { add_want(list, n, i, (int)(pw * k * ui::scale), THUMB); }
			ui::text(string::tformat("%d", i + 1), cell.x + cell.width / 2 - 8, cell.y + cell.height - 24, 13, i == cur_page ? ui::FG : ui::FG4);
			if (ui::clicked(cell)) go_page(i);
		}
		ui::end_clip();
		ui::scrollbar(area, bar_scroll, content);
	}
	else
	{
		if (!engine::outline_count) { ui::text("No table of contents", 16, area.y + 12, 14, ui::GRAY); return; }
		float content = (float)engine::outline_count * TOC_ROW;
		bar_scroll = ui::scroll_wheel(area, bar_scroll, content);
		ui::begin_clip(area);
		int first = math::max(0, (int)(bar_scroll / TOC_ROW));
		int end = math::min(engine::outline_count, first + (int)(area.height / TOC_ROW) + 2);
		for (int i = first; i < end; i++)
		{
			engine::OutlineItem* it = &engine::outline[i];
			Rect row = { 6, area.y + (float)i * TOC_ROW - bar_scroll, BAR_W - 17, TOC_ROW - 2 };
			if (ui::hover(row)) ui::panel(row, ui::BG1, 4);
			float indent = (float)math::min(it.depth, 6) * 12;
			String pg = it.page >= 0 ? string::tformat("%d", it.page + 1) : "";
			float pgw = ui::text_w(pg, 12) + 6;
			ui::text_fit(txt::view(&it.title), row.x + 8 + indent, row.y + 7, row.width - 16 - indent - pgw, 14, it.depth == 0 ? ui::FG : ui::FG4);
			ui::text(pg, row.x + row.width - pgw, row.y + 8, 12, ui::GRAY);
			if (it.page >= 0 && ui::clicked(row)) go_page(it.page);
		}
		ui::end_clip();
		ui::scrollbar(area, bar_scroll, content);
	}
}

<* Presenter view: fullscreen, one page fitted, black around it; the next page is rendered ahead. *>
fn void present(float w, float h) => @pool()
{
	ui::panel({ 0, 0, w, h }, (Color){ 0, 0, 0, 255 });
	int last = engine::pages - 1;
	if (ui::top == 0)
	{
		if (ui::repeat(rl::RLKeyboardKey.RIGHT) || ui::repeat(rl::RLKeyboardKey.DOWN) || ui::repeat(rl::RLKeyboardKey.SPACE) || ui::repeat(rl::RLKeyboardKey.PAGE_DOWN)) present_page = math::min(present_page + 1, last);
		if (ui::repeat(rl::RLKeyboardKey.LEFT) || ui::repeat(rl::RLKeyboardKey.UP) || ui::repeat(rl::RLKeyboardKey.PAGE_UP) || ui::repeat(rl::RLKeyboardKey.BACKSPACE)) present_page = math::max(present_page - 1, 0);
		if (rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE) || rl::is_key_pressed(rl::RLKeyboardKey.F5) || ui::letter('q'))
		{
			presenting = false;
			if (rl::is_window_fullscreen()) rl::toggle_fullscreen();
			go_page(present_page);
			return;
		}
	}
	float pw = engine::sizes[present_page * 2];
	float ph = engine::sizes[present_page * 2 + 1];
	float k = math::min(w / pw, h / ph);
	Rect r = { (w - pw * k) / 2, (h - ph * k) / 2, pw * k, ph * k };
	engine::Want[4] list;
	int n;
	add_want(&list, &n, present_page, (int)(pw * k * ui::scale), PAGE);
	if (present_page < last) add_want(&list, &n, present_page + 1, (int)(engine::sizes[(present_page + 1) * 2] * k * ui::scale), PAGE);
	send_wants(&list, n);
	Tex* t = find_tex(present_page, PAGE);
	ui::panel(r, PAGE_WHITE);
	if (t) { t.used = ++clock; rl::draw_texture_pro(t.tex, { 0, 0, (float)t.tex.width, (float)t.tex.height }, r, { 0, 0 }, 0, rl::WHITE); }
}

// ------------------------------------------------------------------------------------------- Ctrl+K

fn String ocr_line()
{
	if (!ocr::detected) return "checking…";
	if (txt::empty(&ocr::program)) return "tesseract not found (install tesseract-ocr + a language, e.g. tesseract-ocr-eng)";
	if (txt::empty(&ocr::langs)) return string::tformat("%s · no text language installed (have: %s)", txt::view(&ocr::version), txt::view(&ocr::installed));
	return string::tformat("%s%s · using %s · installed: %s", txt::view(&ocr::version), ocr_on ? "" : " (off)", txt::view(&ocr::langs), txt::view(&ocr::installed));
}

fn void collect_about() => @pool()
{
	ui::about_reset("mzp", env::PROJECT_VERSION);
	ui::about_add("File", txt::view(&file_path));
	if (!txt::empty(&engine::title)) ui::about_add("Title", txt::view(&engine::title));
	if (!txt::empty(&engine::author)) ui::about_add("Author", txt::view(&engine::author));
	ui::about_add("Pages", string::tformat("%d", engine::pages));
	ui::about_add("PDFium", "chromium/8165 (pdfium-binaries, BSD-3 / Apache-2.0)");
	ui::about_add("OCR", ocr_line());
	ui::about_add("Settings", txt::view(&config_file));
}

fn void settings_draw() => @pool()
{
	if (!settings_open) return;
	ui::layer = 1;
	Rect box = ui::dialog(720, 600);
	if (ui::dialog_header(box, ui::I_GEAR, "mzp") || rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) settings_open = false;
	float x = box.x + 16;
	float bw = box.width - 32;
	float tw = (bw - 16) / 3;
	if (ui::button({ x, box.y + 54, tw, 36 }, "Shortcuts", settings_tab == 0 ? PRIMARY : NORMAL)) settings_tab = 0;
	if (ui::button({ x + tw + 8, box.y + 54, tw, 36 }, "General", settings_tab == 2 ? PRIMARY : NORMAL)) settings_tab = 2;
	if (ui::button({ x + (tw + 8) * 2, box.y + 54, tw, 36 }, "About", settings_tab == 1 ? PRIMARY : NORMAL)) { settings_tab = 1; collect_about(); }
	Rect area = { x, box.y + 102, bw, box.height - 118 };
	if (settings_tab == 0) { help_scroll = ui::shortcut_table(area, &help_rows, help_scroll); }
	else if (settings_tab == 1) { ui::about_draw(area); }
	else
	{
		bool usable = ocr::detected && ocr::available;
		if (usable)
		{
			if (ui::checkbox(area.x + 4, area.y + 8, "Read scanned pages (OCR)", &ocr_on)) { engine::set_ocr(ocr_on); prefs_dirty = true; }
		}
		else
		{
			// Greyed out: the setting is kept, but there is nothing to switch.
			ui::outline({ area.x + 4, area.y + 8, 24, 24 }, ui::BG2, 4);
			if (ocr_on) ui::text(ui::I_CHECK, area.x + 9, area.y + 12, 14, ui::BG3);
			ui::text("Read scanned pages (OCR)", area.x + 38, area.y + 12, 15, ui::BG4);
		}
		ui::text_fit(ocr_line(), area.x + 4, area.y + 44, area.width - 8, 13, usable ? ui::FG4 : ui::GRAY);
		ui::text_fit("Pages without a text layer are recognized with tesseract when you search or select; results are cached.", area.x + 4, area.y + 66, area.width - 8, 13, ui::GRAY);
	}
	ui::layer = 0;
}
