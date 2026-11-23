module mzp::ocr;
import std::thread, std::math, std::core::string, libc;
import bmu::txt, bmu::sys;

// Optional OCR for scanned pages through the `tesseract` program (Apache-2.0; also `tesseract-ocr` on Void).
// Nothing is bundled: without it mzp works as before. The engine thread renders a scanned page in grey at 300 DPI
// and submits it; worker processes run tesseract in parallel and turn its TSV words into characters with boxes
// (fractions of the page), cached in memory and in ~/.cache/mzp so reopening a document is instant.

extern fn CInt c_pipe(CInt* fds) @cname("pipe") @private;
extern fn sz c_read(CInt fd, void* buf, usz n) @cname("read") @private;
extern fn CLong c_sysconf(CInt name) @cname("sysconf") @private;
extern fn CInt c_setenv(ZString name, ZString value, CInt overwrite) @cname("setenv") @private;
extern fn CInt c_unlink(ZString path) @cname("unlink") @private;

const int MAX_WORKERS = 4;
const int QUEUE = 16;
const int MAX_PAGES = 100_000;

struct Result
{
	int count;
	uint* chars;
	float* boxes;              // 4 per char: left, top, right, bottom (fractions of the page, y from the top)
}

struct Job { int page; char* gray; int width; int height; }

bool available;
bool detected;              // detection finished (the strings below are final)
char[256] program;
char[64] version;
char[256] installed;           // "deu, deu_frak"
char[128] langs;               // "deu" (passed to -l)
char[4096] cache_dir;          // ~/.cache/mzp/<key>
int workers;

thread::Mutex mutex;
thread::ConditionVariable wake;
thread::Thread[MAX_WORKERS] threads;
bool quit;
Job[QUEUE] queue;
int queued;
Result** results;              // per page; null = not recognized yet
bool* pending;                 // per page: rendered + queued or running
int pages;
thread::ConditionVariable* notify_cv;   // the engine's wake signal (results arrive while it waits)
thread::Mutex* notify_mutex;

<* Run a program, capture stdout (bounded). Returns the bytes read or -1. Used for --version / --list-langs / OCR. *>
fn sz run_capture(ZString[] argv, char[] out, bool one_thread)
{
	CInt[2] p;
	if (c_pipe(&p) != 0) return -1;
	CInt pid = sys::c_fork();
	if (pid == 0)
	{
		sys::c_dup2(p[1], 1);
		CInt devnull = sys::c_open("/dev/null", sys::O_WRONLY);
		if (devnull >= 0) sys::c_dup2(devnull, 2);
		if (one_thread) c_setenv("OMP_THREAD_LIMIT", "1", 1); // several pages run in parallel instead
		sys::c_execvpe(argv[0], argv.ptr, sys::environ);
		sys::c_exit(127);
	}
	sys::c_close(p[1]);
	if (pid < 0) { sys::c_close(p[0]); return -1; }
	usz n;
	while (n < out.len)
	{
		sz r = c_read(p[0], &out[n], out.len - n);
		if (r <= 0) break;
		n += (usz)r;
	}
	// Drain the rest so the child never blocks, then reap it.
	char[4096] sink;
	while (c_read(p[0], &sink, sink.len) > 0) {}
	sys::c_close(p[0]);
	CInt status;
	sys::c_waitpid(pid, &status, 0);
	return status == 0 ? (sz)n : -1;
}

<* Find tesseract and its languages; called once on the engine thread (never the UI thread). *>
fn void detect(String pdf_path, long size, long mtime, int page_count) => @pool()
{
	defer detected = true;
	pages = page_count;
	foreach (name : (String[]){ "tesseract", "tesseract-ocr" })
	{
		char[4096] out;
		ZString[3] argv = { name.zstr_tcopy(), "--version", null };
		sz n = run_capture(&argv, &out, false);
		if (n <= 0) continue;
		txt::set(&program, name);
		String first = ((String)out[:(usz)n]).tsplit("\n")[0];
		txt::set(&version, first.trim());
		break;
	}
	if (txt::empty(&program)) return;
	char[8192] out;
	ZString[3] argv = { txt::z(&program), "--list-langs", null };
	sz n = run_capture(&argv, &out, false);
	if (n <= 0) return;
	String usable;
	String fraktur;
	foreach (line : ((String)out[:(usz)n]).tsplit("\n"))
	{
		String l = line.trim();
		if (!l.len || l.contains(" ") || l.contains(":")) continue;
		txt::append(&installed, txt::empty(&installed) ? l : string::tformat(", %s", l));
		if (l == "osd" || l == "equ") continue;
		if (l.ends_with("_frak")) { fraktur = fraktur.len ? string::tformat("%s+%s", fraktur, l) : l; continue; }
		if (usable.len + l.len + 1 < langs.len) usable = usable.len ? string::tformat("%s+%s", usable, l) : l;
	}
	txt::set(&langs, usable.len ? usable : fraktur);
	if (txt::empty(&langs)) return;
	// Cache key: path, size and modification time.
	ulong hash = 1469598103934665603;
	foreach (c : string::tformat("%s|%d|%d", pdf_path, size, mtime)) { hash ^= c; hash *= 1099511628211; }
	String base = sys::env("XDG_CACHE_HOME");
	if (!base.starts_with("/")) base = txt::join(sys::home(), ".cache");
	txt::set(&cache_dir, string::tformat("%s/mzp/%x-%s", base, hash, txt::view(&langs)));
	results = libc::calloc((usz)math::max(page_count, 1), usz::size);
	pending = libc::calloc((usz)math::max(page_count, 1), bool::size);
	if (!results || !pending || page_count > MAX_PAGES) return;
	if (catch mutex.init()) return;
	if (catch wake.init()) return;
	workers = math::clamp((int)c_sysconf(84) / 2, 1, MAX_WORKERS); // _SC_NPROCESSORS_ONLN
	for (int i = 0; i < workers; i++) if (catch threads[i].create(&work, null)) { workers = i; break; }
	available = workers > 0;
}

fn void close()
{
	if (!available) return;
	mutex.lock();
	quit = true;
	wake.broadcast();
	mutex.unlock();
	for (int i = 0; i < workers; i++) threads[i].join()!!;
	for (int i = 0; i < queued; i++) libc::free(queue[i].gray);
}

<* After close() (engine thread joined): forget the document so detect() can run for the next one. UI thread. *>
fn void reset()
{
	if (available) { wake.destroy(); mutex.destroy(); }
	if (results) { for (int i = 0; i < pages; i++) free_result(results[i]); libc::free(results); }
	libc::free(pending);
	results = null;
	pending = null;
	available = false;
	detected = false;
	quit = false;
	workers = 0;
	queued = 0;
	pages = 0;
	program = {};
	version = {};
	installed = {};
	langs = {};
	cache_dir = {};
}

<* Recognized text of a page (memory, else the disk cache), or null. Engine thread. *>
fn Result* get(int page) => @pool()
{
	if (!available || page < 0 || page >= pages) return null;
	mutex.lock();
	Result* r = results[page];
	mutex.unlock();
	if (r) return r;
	String? tsv = sys::read_temp(string::tformat("%s/p%d.tsv", txt::view(&cache_dir), page));
	if (catch tsv) return null;
	r = parse(tsv);
	mutex.lock();
	if (!results[page]) { results[page] = r; } else { free_result(r); r = results[page]; }
	mutex.unlock();
	return r;
}

fn bool is_pending(int page)
{
	if (!available || page < 0 || page >= pages) return false;
	mutex.lock();
	bool p = pending[page];
	mutex.unlock();
	return p;
}

<* Queue a rendered grey page (ownership of `gray` passes on). False when the queue is full (caller frees). *>
fn bool submit(int page, char* gray, int width, int height)
{
	if (!available) return false;
	mutex.lock();
	defer mutex.unlock();
	if (queued >= QUEUE || pending[page]) return false;
	pending[page] = true;
	queue[queued++] = { page, gray, width, height };
	wake.signal();
	return true;
}

fn void free_result(Result* r)
{
	if (!r) return;
	libc::free(r.chars);
	libc::free(r.boxes);
	libc::free(r);
}

<*
 Tesseract TSV (level page block par line word left top width height conf text) -> characters with boxes. A
 word's box is shared out evenly over its letters; words get a space between them and lines a newline. The first
 data row (level 1) carries the image size used to turn pixels into fractions.
*>
fn Result* parse(String tsv) => @pool()
{
	Result* r = libc::calloc(1, Result::size);
	if (!r) return null;
	usz cap = tsv.len + 16;
	r.chars = libc::malloc(cap * uint::size);
	r.boxes = libc::malloc(cap * 4 * float::size);
	if (!r.chars || !r.boxes) { free_result(r); return null; }
	float iw = 1;
	float ih = 1;
	int last_line = -1;
	foreach (line : tsv.tsplit("\n"))
	{
		String[] f = line.tsplit("\t");
		if (f.len < 12) continue;
		int? level = f[0].to_int();
		if (catch level) continue; // header
		int? left = f[6].to_int();
		int? top = f[7].to_int();
		int? wd = f[8].to_int();
		int? ht = f[9].to_int();
		if (catch left, top, wd, ht) continue;
		if (level == 1) { iw = (float)math::max(wd, 1); ih = (float)math::max(ht, 1); continue; }
		if (level != 5) continue;
		String word = f[11].trim();
		if (!word.len) continue;
		int line_id = (f[2].to_int() ?? 0) * 100000 + (f[3].to_int() ?? 0) * 1000 + (f[4].to_int() ?? 0);
		float x0 = (float)left / iw;
		float y0 = (float)top / ih;
		float x1 = (float)(left + wd) / iw;
		float y1 = (float)(top + ht) / ih;
		if (r.count > 0 && (usz)r.count + 1 < cap)
		{
			uint sep = line_id != last_line ? '\n' : ' ';
			r.chars[r.count] = sep;
			r.boxes[r.count * 4] = 0; r.boxes[r.count * 4 + 1] = 0; r.boxes[r.count * 4 + 2] = 0; r.boxes[r.count * 4 + 3] = 0;
			r.count++;
		}
		last_line = line_id;
		// Decode UTF-8 codepoints of the word, then share the width.
		uint[256] cps;
		int n;
		for (usz i = 0; i < word.len && n < cps.len;)
		{
			uint c = word[i];
			usz len = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
			if (len > 1) c &= len == 2 ? 0x1F : len == 3 ? 0x0F : 0x07;
			for (usz k = 1; k < len && i + k < word.len; k++) c = (c << 6) | (word[i + k] & 0x3F);
			i += len;
			cps[n++] = c;
		}
		for (int i = 0; i < n && (usz)r.count < cap; i++)
		{
			r.chars[r.count] = cps[i];
			float* b = &r.boxes[r.count * 4];
			b[0] = x0 + (x1 - x0) * (float)i / (float)n;
			b[1] = y0;
			b[2] = x0 + (x1 - x0) * (float)(i + 1) / (float)n;
			b[3] = y1;
			r.count++;
		}
	}
	return r;
}

fn int work(void* arg)
{
	@pool_init(mem, 256 * 1024) { serve(); };
	return 0;
}

fn void serve()
{
	while (true)
	{
		mutex.lock();
		while (!quit && !queued) wake.wait(&mutex);
		if (quit) { mutex.unlock(); return; }
		Job j = queue[0];
		for (int i = 1; i < queued; i++) queue[i - 1] = queue[i];
		queued--;
		mutex.unlock();
		Result* r = recognize(j);
		libc::free(j.gray);
		mutex.lock();
		if (!results[j.page]) { results[j.page] = r ? r : libc::calloc(1, Result::size); } else { free_result(r); }
		pending[j.page] = false;
		mutex.unlock();
		if (notify_mutex) { notify_mutex.lock(); notify_cv.signal(); notify_mutex.unlock(); }
	}
}

<* Write the page as PGM, run tesseract (TSV to stdout), keep the TSV in the cache, parse it. *>
fn Result* recognize(Job j) => @pool()
{
	sys::mkdirs(txt::view(&cache_dir));
	String pgm = string::tformat("%s/.p%d.pgm", txt::view(&cache_dir), j.page);
	CInt fd = sys::c_open(pgm.zstr_tcopy(), sys::O_WRONLY | sys::O_CREAT | sys::O_TRUNC, (CInt)0o600);
	if (fd < 0) return null;
	String head = string::tformat("P5\n%d %d\n255\n", j.width, j.height);
	sys::c_write(fd, head.ptr, head.len);
	usz total = (usz)j.width * (usz)j.height;
	for (usz done; done < total;)
	{
		sz w = sys::c_write(fd, j.gray + done, total - done);
		if (w <= 0) break;
		done += (usz)w;
	}
	sys::c_close(fd);
	usz cap = 4 * 1024 * 1024;
	char* buf = libc::malloc(cap);
	if (!buf) return null;
	defer libc::free(buf);
	ZString[9] argv = { txt::z(&program), pgm.zstr_tcopy(), "stdout", "-l", txt::z(&langs), "--psm", "3", "tsv", null };
	sz n = run_capture(&argv, buf[:cap], true);
	c_unlink(pgm.zstr_tcopy());
	if (n <= 0) return null;
	String tsv = (String)buf[:(usz)n];
	String file = string::tformat("%s/p%d.tsv", txt::view(&cache_dir), j.page);
	String tmp = string::tformat("%s/.p%d.tmp", txt::view(&cache_dir), j.page);
	if (sys::write_file(tmp, tsv)) sys::move(tmp, file);
	return parse(tsv);
}
