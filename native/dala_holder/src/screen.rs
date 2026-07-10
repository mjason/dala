//! Server-side terminal emulation (the tmux/zellij model).
//!
//! Every byte the PTY produces is fed into a headless alacritty terminal,
//! which maintains the screen grid, scrollback and terminal modes. On attach
//! we synthesize a bounded repaint — history tail, current screen, cursor,
//! modes — instead of replaying the raw byte history, so attaching is O(grid)
//! regardless of how much output the session ever produced.

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, CursorShape, NamedColor, Processor};

#[derive(Clone)]
struct Quiet;

impl EventListener for Quiet {
    fn send_event(&self, _event: Event) {}
}

struct Size {
    lines: usize,
    columns: usize,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.lines
    }

    fn screen_lines(&self) -> usize {
        self.lines
    }

    fn columns(&self) -> usize {
        self.columns
    }
}

pub struct Screen {
    term: Term<Quiet>,
    parser: Processor,
}

impl Screen {
    pub fn new(rows: u16, cols: u16, history_lines: usize) -> Self {
        let config = Config {
            scrolling_history: history_lines,
            ..Config::default()
        };
        let size = Size {
            lines: rows.max(1) as usize,
            columns: cols.max(1) as usize,
        };
        Screen {
            term: Term::new(config, &size, Quiet),
            parser: Processor::new(),
        }
    }

    pub fn advance(&mut self, bytes: &[u8]) {
        self.parser.advance(&mut self.term, bytes);
    }

    pub fn columns(&self) -> usize {
        self.term.grid().columns()
    }

    pub fn resize(&mut self, rows: u16, cols: u16) {
        self.term.resize(Size {
            lines: rows.max(1) as usize,
            columns: cols.max(1) as usize,
        });
    }

    /// Synthesized full repaint: reset, history tail, screen, cursor, modes.
    /// `soft_wrap` renders wrapped rows without explicit newlines so the
    /// client rebuilds logical lines — only valid when the client's width
    /// matches this grid; otherwise hard breaks keep the layout intact.
    pub fn repaint(&self, soft_wrap: bool) -> Vec<u8> {
        let term = &self.term;
        let grid = term.grid();
        let mode = *term.mode();
        let columns = grid.columns();
        let screen_lines = grid.screen_lines();
        let mut out: Vec<u8> = Vec::with_capacity(64 * 1024);

        out.extend_from_slice(b"\x1bc");

        let alt = mode.contains(TermMode::ALT_SCREEN);
        let mut pen = Pen::default();

        if alt {
            out.extend_from_slice(b"\x1b[?1049h");
        } else {
            // Oldest history line first; the grid indexes history as negative
            // lines. The alt screen has no history.
            let history = grid.history_size();
            for i in 0..history {
                let line = Line(i as i32 - history as i32);
                // Wrapped rows flow into the next one without an explicit
                // newline, so xterm re-marks them as one logical line and
                // copying a long command yields no hard breaks.
                if !render_row(&mut out, &mut pen, grid, line, columns, soft_wrap) {
                    out.extend_from_slice(b"\r\n");
                }
            }
        }

        for i in 0..screen_lines {
            let wrapped = render_row(&mut out, &mut pen, grid, Line(i as i32), columns, soft_wrap);
            if !wrapped && i + 1 < screen_lines {
                out.extend_from_slice(b"\r\n");
            }
        }

        // Cursor position is 1-based in CUP.
        let cursor = grid.cursor.point;
        out.extend_from_slice(
            format!("\x1b[0m\x1b[{};{}H", cursor.line.0 + 1, cursor.column.0 + 1).as_bytes(),
        );

        render_modes(&mut out, term, &mode);
        out
    }
}

fn render_modes(out: &mut Vec<u8>, term: &Term<Quiet>, mode: &TermMode) {
    let mut set = |flag: TermMode, seq: &[u8]| {
        if mode.contains(flag) {
            out.extend_from_slice(seq);
        }
    };
    set(TermMode::APP_CURSOR, b"\x1b[?1h");
    set(TermMode::APP_KEYPAD, b"\x1b=");
    set(TermMode::BRACKETED_PASTE, b"\x1b[?2004h");
    set(TermMode::FOCUS_IN_OUT, b"\x1b[?1004h");
    set(TermMode::MOUSE_REPORT_CLICK, b"\x1b[?1000h");
    set(TermMode::MOUSE_DRAG, b"\x1b[?1002h");
    set(TermMode::MOUSE_MOTION, b"\x1b[?1003h");
    set(TermMode::UTF8_MOUSE, b"\x1b[?1005h");
    set(TermMode::SGR_MOUSE, b"\x1b[?1006h");
    set(TermMode::ALTERNATE_SCROLL, b"\x1b[?1007h");
    set(TermMode::INSERT, b"\x1b[4h");
    set(TermMode::LINE_FEED_NEW_LINE, b"\x1b[20h");

    if !mode.contains(TermMode::SHOW_CURSOR) {
        out.extend_from_slice(b"\x1b[?25l");
    }

    let style = term.cursor_style();
    let decscusr = match (style.shape, style.blinking) {
        (CursorShape::Block, true) => 1,
        (CursorShape::Block, false) => 2,
        (CursorShape::Underline, true) => 3,
        (CursorShape::Underline, false) => 4,
        (CursorShape::Beam, true) => 5,
        (CursorShape::Beam, false) => 6,
        _ => 2,
    };
    out.extend_from_slice(format!("\x1b[{decscusr} q").as_bytes());
}

/// Renders one row. Returns true when the row wraps into the next one, in
/// which case every column was emitted and no newline must follow — the
/// terminal's auto-wrap continues the logical line.
fn render_row(
    out: &mut Vec<u8>,
    pen: &mut Pen,
    grid: &alacritty_terminal::grid::Grid<Cell>,
    line: Line,
    columns: usize,
    soft_wrap: bool,
) -> bool {
    let row = &grid[line];
    let wrapped =
        soft_wrap && columns > 0 && row[Column(columns - 1)].flags.contains(Flags::WRAPLINE);

    // Trim trailing cells that would render as nothing (never on wrapped
    // rows: auto-wrap needs the full width written out).
    let mut end = if wrapped { columns } else { 0 };
    if !wrapped {
        for i in (0..columns).rev() {
            let cell = &row[Column(i)];
            if cell.c != ' '
                || cell.bg != Color::Named(NamedColor::Background)
                || cell
                    .flags
                    .intersects(Flags::INVERSE | Flags::ALL_UNDERLINES | Flags::STRIKEOUT)
            {
                end = i + 1;
                break;
            }
        }
    }

    for i in 0..end {
        let cell = &row[Column(i)];
        if cell
            .flags
            .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
        {
            continue;
        }
        pen.apply(out, cell);

        let mut buf = [0u8; 4];
        out.extend_from_slice(cell.c.encode_utf8(&mut buf).as_bytes());
        if let Some(extra) = cell.zerowidth() {
            for ch in extra {
                out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
            }
        }
    }

    if !wrapped {
        // Reset the pen and wipe whatever an older frame left beyond the trim.
        out.extend_from_slice(b"\x1b[0m\x1b[K");
        *pen = Pen::default();
    }

    wrapped
}

/// Tracks the active SGR state and emits a minimal SGR sequence on change.
struct Pen {
    fg: Color,
    bg: Color,
    flags: Flags,
}

impl Default for Pen {
    fn default() -> Self {
        Pen {
            fg: Color::Named(NamedColor::Foreground),
            bg: Color::Named(NamedColor::Background),
            flags: Flags::empty(),
        }
    }
}

const STYLE_FLAGS: Flags = Flags::BOLD
    .union(Flags::DIM)
    .union(Flags::ITALIC)
    .union(Flags::ALL_UNDERLINES)
    .union(Flags::INVERSE)
    .union(Flags::HIDDEN)
    .union(Flags::STRIKEOUT);

impl Pen {
    fn apply(&mut self, out: &mut Vec<u8>, cell: &Cell) {
        let flags = cell.flags & STYLE_FLAGS;
        if self.fg == cell.fg && self.bg == cell.bg && self.flags == flags {
            return;
        }
        self.fg = cell.fg;
        self.bg = cell.bg;
        self.flags = flags;

        let mut sgr = String::from("\x1b[0");
        if flags.contains(Flags::BOLD) {
            sgr.push_str(";1");
        }
        if flags.contains(Flags::DIM) {
            sgr.push_str(";2");
        }
        if flags.contains(Flags::ITALIC) {
            sgr.push_str(";3");
        }
        if flags.intersects(Flags::ALL_UNDERLINES) {
            sgr.push_str(";4");
        }
        if flags.contains(Flags::INVERSE) {
            sgr.push_str(";7");
        }
        if flags.contains(Flags::HIDDEN) {
            sgr.push_str(";8");
        }
        if flags.contains(Flags::STRIKEOUT) {
            sgr.push_str(";9");
        }
        push_color(&mut sgr, &cell.fg, false);
        push_color(&mut sgr, &cell.bg, true);
        sgr.push('m');
        out.extend_from_slice(sgr.as_bytes());
    }
}

fn push_color(sgr: &mut String, color: &Color, background: bool) {
    let base = if background { 40 } else { 30 };
    match color {
        Color::Named(named) => {
            let code: Option<u8> = match named {
                NamedColor::Black => Some(0),
                NamedColor::Red => Some(1),
                NamedColor::Green => Some(2),
                NamedColor::Yellow => Some(3),
                NamedColor::Blue => Some(4),
                NamedColor::Magenta => Some(5),
                NamedColor::Cyan => Some(6),
                NamedColor::White => Some(7),
                NamedColor::BrightBlack => Some(60),
                NamedColor::BrightRed => Some(61),
                NamedColor::BrightGreen => Some(62),
                NamedColor::BrightYellow => Some(63),
                NamedColor::BrightBlue => Some(64),
                NamedColor::BrightMagenta => Some(65),
                NamedColor::BrightCyan => Some(66),
                NamedColor::BrightWhite => Some(67),
                // Foreground/Background and the dim variants render as the
                // default pen, which "\x1b[0" already restored.
                _ => None,
            };
            if let Some(code) = code {
                sgr.push_str(&format!(";{}", base + code as u16));
            }
        }
        Color::Indexed(index) => {
            sgr.push_str(&format!(";{};5;{}", if background { 48 } else { 38 }, index));
        }
        Color::Spec(rgb) => {
            sgr.push_str(&format!(
                ";{};2;{};{};{}",
                if background { 48 } else { 38 },
                rgb.r,
                rgb.g,
                rgb.b
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(bytes: &[u8]) -> String {
        String::from_utf8_lossy(bytes).into_owned()
    }

    #[test]
    fn repaint_carries_screen_content_and_colors() {
        let mut screen = Screen::new(24, 80, 100);
        screen.advance(b"hello \x1b[31mred\x1b[0m plain\r\nsecond line");
        let out = text(&screen.repaint(true));

        assert!(out.starts_with("\x1bc"));
        assert!(out.contains("hello "));
        assert!(out.contains("\x1b[0;31mred"));
        assert!(out.contains("second line"));
        // Cursor lands after "second line" on row 2.
        assert!(out.contains("\x1b[2;12H"));
    }

    #[test]
    fn repaint_restores_alt_screen_and_modes() {
        let mut screen = Screen::new(10, 40, 100);
        screen.advance(b"\x1b[?1049h\x1b[?25l\x1b[?2004h\x1b[?1002h\x1b[?1006hTUI");
        let out = text(&screen.repaint(true));

        assert!(out.contains("\x1b[?1049h"));
        assert!(out.contains("\x1b[?25l"));
        assert!(out.contains("\x1b[?2004h"));
        assert!(out.contains("\x1b[?1002h"));
        assert!(out.contains("\x1b[?1006h"));
        assert!(out.contains("TUI"));
    }

    #[test]
    fn history_scrolls_ahead_of_screen() {
        let mut screen = Screen::new(4, 20, 100);
        for i in 0..10 {
            screen.advance(format!("line-{i}\r\n").as_bytes());
        }
        let out = text(&screen.repaint(true));

        // 11 rows used (10 lines + prompt row), 4 on screen, rest history.
        assert!(out.contains("line-0"));
        assert!(out.contains("line-9"));
        assert!(
            out.find("line-0").unwrap() < out.find("line-9").unwrap(),
            "history must render oldest-first"
        );
    }

    #[test]
    fn wide_chars_render_once() {
        let mut screen = Screen::new(5, 20, 10);
        screen.advance("中文 ok".as_bytes());
        let out = text(&screen.repaint(true));
        assert_eq!(out.matches('中').count(), 1);
        assert!(out.contains("中文 ok"));
    }

    #[test]
    fn wrapped_lines_carry_no_hard_breaks() {
        let mut screen = Screen::new(5, 10, 50);
        // 25 chars in a 10-column terminal: wraps across three rows.
        screen.advance(b"ABCDEFGHIJKLMNOPQRSTUVWXY");
        let out = text(&screen.repaint(true));

        let a = out.find("ABCDEFGHIJ").expect("first segment");
        let tail = &out[a..];
        let upto = tail.find("UVWXY").expect("last segment");
        assert!(
            !tail[..upto].contains("\r\n"),
            "wrapped segments must not be separated by newlines: {:?}",
            &tail[..upto]
        );
    }

    #[test]
    fn width_mismatch_falls_back_to_hard_breaks() {
        let mut screen = Screen::new(5, 10, 50);
        screen.advance(b"ABCDEFGHIJKLMNOPQRSTUVWXY");
        let out = text(&screen.repaint(false));
        let a = out.find("ABCDEFGHIJ").expect("first segment");
        assert!(out[a..].contains("\r\n"), "hard-break mode must keep row newlines");
    }

    #[test]
    fn resize_is_reflected() {
        let mut screen = Screen::new(24, 80, 10);
        screen.resize(30, 100);
        screen.advance(b"after resize");
        let out = text(&screen.repaint(true));
        assert!(out.contains("after resize"));
    }
}
