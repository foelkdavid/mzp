module mzp;
import std::math, std::core::string;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::sys, bmu::picker;

// mzp - built on bmu (docs: bmu/docs/README.md, one page: bmu/docs/QUICK_REFERENCE.md).
// Run: c3c build && ./build/mzp        Screenshot check: ./build/mzp --shot out.png

const int ID_SEARCH = 1;      // input ids: unique per field (picker uses 9000+)
const int PICK_OPEN = 1;      // picker purposes

char[128] search;
char[1024] opened;
bool about_open;

fn void main(String[] args)
{
	ui::open("mzp", 1100, 720, 800, 500);
	defer ui::close();
	ui::app_args(args);
	while (ui::running()) frame();
}

fn void frame() => @pool()
{
	ui::frame_begin(about_open || picker::open);
	if (ui::top == 0 && ui::ctrl_down() && ui::letter('f')) ui::focus_on(ID_SEARCH, &search);
	float w = ui::sw();
	float h = ui::sh();

	// top bar
	ui::panel({ 0, 0, w, 64 }, ui::BG_HARD);
	ui::hline(0, 63, w, ui::BG1);
	ui::text(ui::I_STAR, 20, 20, 20, ui::YELLOW);
	ui::text("mzp", 52, 16, 24, ui::FG);
	if (ui::icon_button({ w - 56, 12, 40, 40 }, ui::I_INFO, ui::FG4, "About")) about_open = true;
	if (ui::button({ w - 216, 12, 150, 40 }, "Open…", PRIMARY, ui::I_FOLDER_OPEN)) picker::start(PICK_OPEN, FILE, "Open a file", txt::view(&picker::last_dir));
	ui::input(ID_SEARCH, { w - 546, 14, 320, 36 }, &search, "Search (Ctrl+F)", null, ui::I_SEARCH);

	// content
	ui::text(txt::empty(&opened) ? "Nothing opened yet." : txt::view(&opened), 24, 90, 15, ui::FG4);

	// status bar
	ui::panel({ 0, h - 26, w, 26 }, ui::BG_HARD);
	ui::text(string::tformat("UI scale %d%%  ·  Ctrl +/-/0", (int)(ui::scale * 100 + 0.5f)), 16, h - 20, 13, ui::GRAY);

	// modals (layer 1), picker last
	ui::layer = 1;
	if (about_open)
	{
		Rect box = ui::dialog(460, 200);
		if (ui::dialog_header(box, ui::I_INFO, "About mzp") || (ui::live() && rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE))) about_open = false;
		ui::text("Made with bmu.", box.x + 24, box.y + 80, 15, ui::FG4);
	}
	if (picker::open) picker::draw();
	ui::layer = 0;

	int why;
	String path;
	if (picker::take(&why, &path) && why == PICK_OPEN) txt::set(&opened, path);
	ui::frame_end();
}
