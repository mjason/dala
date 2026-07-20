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
use serde::Serialize;
use std::collections::VecDeque;

/// Byte budget for the scrollback portion of an attach repaint. The client
/// parses the whole repaint synchronously; ~512 KiB is tens of milliseconds
/// of xterm parsing (thousands of ordinary lines) — a snappy attach — while
/// the full history could reach many megabytes under a chatty AI TUI.
pub const REPAINT_HISTORY_BUDGET: usize = 512 * 1024;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TextSnapshot {
    pub mode: &'static str,
    pub lines: Vec<String>,
    pub cached_line_count: usize,
    pub truncated: bool,
    pub rows: usize,
    pub columns: usize,
    pub cursor: TextCursor,
    pub input_modes: InputModes,
    pub highlighted_ranges: Vec<HighlightedRange>,
    pub highlights_truncated: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TextCursor {
    pub row: i32,
    pub column: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InputModes {
    pub application_cursor: bool,
    pub application_keypad: bool,
    pub bracketed_paste: bool,
    pub mouse_tracking: bool,
    pub cursor_visible: bool,
}

/// A visible run using inverse video or a non-default background. TUIs use
/// these attributes for selected rows, active buttons and focused controls.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HighlightedRange {
    pub row: usize,
    pub start_column: usize,
    pub end_column: usize,
    pub text: String,
    pub foreground: String,
    pub background: String,
    pub inverse: bool,
    pub bold: bool,
    pub dim: bool,
}

const MAX_HIGHLIGHT_RANGES: usize = 256;

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
        self.repaint_with_history(soft_wrap, REPAINT_HISTORY_BUDGET)
    }

    /// Repaint with a caller-selected scrollback byte budget. A zero budget
    /// paints only the current viewport, which keeps cold session switches
    /// interactive while the holder retains full history for an on-demand
    /// repaint later.
    pub fn repaint_with_history(&self, soft_wrap: bool, history_budget: usize) -> Vec<u8> {
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
            // The repaint is parsed synchronously on the client's main
            // thread, so an unbounded history (up to 50k SGR-heavy lines =
            // many megabytes) would freeze the UI on every attach/switch.
            // A cheap newest-first pre-pass sizes rows until the byte budget
            // is spent, picking the oldest row to emit; the emission below
            // then renders that tail exactly as before (one continuous pen,
            // nothing inserted between soft-wrapped segments).
            let history = grid.history_size();
            let mut first = history;
            let mut used = 0usize;
            for i in (0..history).rev() {
                // The grid indexes history as negative lines; -1 is newest.
                let line = Line(i as i32 - history as i32);
                let mut scratch: Vec<u8> = Vec::with_capacity(64);
                let mut scratch_pen = Pen::default();
                let wrapped = render_row(
                    &mut scratch,
                    &mut scratch_pen,
                    grid,
                    line,
                    columns,
                    soft_wrap,
                );
                let row_len = scratch.len() + if wrapped { 0 } else { 2 };
                if used + row_len > history_budget {
                    break;
                }
                used += row_len;
                first = i;
            }
            // Never start mid-logical-line: if the row before `first` wraps
            // into it, advance to the next logical line start (a partial
            // continuation would render with wrong colours and reflow).
            while first > 0 && first < history {
                let prev = Line(first as i32 - 1 - history as i32);
                let prev_wraps = columns > 0
                    && grid[prev][Column(columns - 1)]
                        .flags
                        .contains(Flags::WRAPLINE);
                if prev_wraps {
                    first += 1;
                } else {
                    break;
                }
            }

            for i in first..history {
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

    /// Plain-text view of the emulator grid for machine consumers. Normal
    /// buffer scrollback is included oldest-first; WRAPLINE rows are joined
    /// into logical lines. Alternate-screen programs return their current
    /// screen only. The retained tail is bounded by both logical lines and
    /// UTF-8 bytes so one pathological terminal line cannot create an
    /// unbounded protocol response.
    pub fn text_snapshot(&self, max_lines: usize, max_bytes: usize) -> TextSnapshot {
        let term = &self.term;
        let grid = term.grid();
        let alt = term.mode().contains(TermMode::ALT_SCREEN);
        let history = if alt { 0 } else { grid.history_size() };
        let start = -(history as i32);
        let cursor = grid.cursor.point;
        let mut end = cursor.line.0.max(0);

        for i in start..grid.screen_lines() as i32 {
            if row_has_text(grid, Line(i), grid.columns()) {
                end = end.max(i);
            }
        }

        let mut retained = VecDeque::new();
        let mut retained_bytes = 0usize;
        let mut cached_line_count = 0usize;
        let mut truncated = false;
        let mut logical = String::new();
        let line_limit = if max_lines == 0 {
            usize::MAX
        } else {
            max_lines
        };
        let byte_limit = max_bytes.max(1);

        for i in start..=end {
            let line = Line(i);
            logical.push_str(&plain_row(grid, line, grid.columns()));
            if row_wraps(grid, line, grid.columns()) {
                continue;
            }

            cached_line_count += 1;
            retained_bytes += logical.len();
            retained.push_back(std::mem::take(&mut logical));

            while retained.len() > line_limit || (retained_bytes > byte_limit && retained.len() > 1)
            {
                if let Some(dropped) = retained.pop_front() {
                    retained_bytes = retained_bytes.saturating_sub(dropped.len());
                    truncated = true;
                }
            }

            if retained_bytes > byte_limit {
                let line = retained.front_mut().expect("one retained line");
                let remove = retained_bytes - byte_limit;
                let split = next_char_boundary(line, remove);
                line.drain(..split);
                retained_bytes = line.len();
                truncated = true;
            }
        }

        if !logical.is_empty() {
            cached_line_count += 1;
            retained_bytes += logical.len();
            retained.push_back(logical);
            while retained.len() > line_limit || (retained_bytes > byte_limit && retained.len() > 1)
            {
                if let Some(dropped) = retained.pop_front() {
                    retained_bytes = retained_bytes.saturating_sub(dropped.len());
                    truncated = true;
                }
            }

            if retained_bytes > byte_limit {
                let line = retained.front_mut().expect("one retained line");
                let remove = retained_bytes - byte_limit;
                let split = next_char_boundary(line, remove);
                line.drain(..split);
                truncated = true;
            }
        }

        let (highlighted_ranges, highlights_truncated) = if alt {
            highlighted_ranges(grid)
        } else {
            (Vec::new(), false)
        };

        TextSnapshot {
            mode: if alt { "alternate" } else { "normal" },
            lines: retained.into_iter().collect(),
            cached_line_count,
            truncated,
            rows: grid.screen_lines(),
            columns: grid.columns(),
            cursor: TextCursor {
                row: cursor.line.0,
                column: cursor.column.0,
            },
            input_modes: input_modes(term.mode()),
            highlighted_ranges,
            highlights_truncated,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct HighlightStyle {
    foreground: Color,
    background: Color,
    inverse: bool,
    bold: bool,
    dim: bool,
}

fn input_modes(mode: &TermMode) -> InputModes {
    InputModes {
        application_cursor: mode.contains(TermMode::APP_CURSOR),
        application_keypad: mode.contains(TermMode::APP_KEYPAD),
        bracketed_paste: mode.contains(TermMode::BRACKETED_PASTE),
        mouse_tracking: mode.intersects(
            TermMode::MOUSE_REPORT_CLICK | TermMode::MOUSE_DRAG | TermMode::MOUSE_MOTION,
        ),
        cursor_visible: mode.contains(TermMode::SHOW_CURSOR),
    }
}

fn highlight_style(cell: &Cell) -> Option<HighlightStyle> {
    let inverse = cell.flags.contains(Flags::INVERSE);
    if !inverse && cell.bg == Color::Named(NamedColor::Background) {
        return None;
    }

    Some(HighlightStyle {
        foreground: cell.fg,
        background: cell.bg,
        inverse,
        bold: cell.flags.contains(Flags::BOLD),
        dim: cell.flags.contains(Flags::DIM),
    })
}

fn highlighted_ranges(
    grid: &alacritty_terminal::grid::Grid<Cell>,
) -> (Vec<HighlightedRange>, bool) {
    let mut ranges = Vec::new();
    let columns = grid.columns();

    for row_index in 0..grid.screen_lines() {
        let row = &grid[Line(row_index as i32)];
        let mut column = 0;

        while column < columns {
            let Some(style) = highlight_style(&row[Column(column)]) else {
                column += 1;
                continue;
            };
            let start = column;
            column += 1;
            while column < columns && highlight_style(&row[Column(column)]) == Some(style) {
                column += 1;
            }

            if ranges.len() >= MAX_HIGHLIGHT_RANGES {
                return (ranges, true);
            }

            ranges.push(HighlightedRange {
                row: row_index,
                start_column: start,
                end_column: column,
                text: plain_range(row, start, column).trim().to_owned(),
                foreground: color_label(style.foreground),
                background: color_label(style.background),
                inverse: style.inverse,
                bold: style.bold,
                dim: style.dim,
            });
        }
    }

    (ranges, false)
}

fn plain_range(row: &alacritty_terminal::grid::Row<Cell>, start: usize, end: usize) -> String {
    let mut out = String::new();
    for i in start..end {
        let cell = &row[Column(i)];
        if cell
            .flags
            .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
        {
            continue;
        }
        out.push(cell.c);
        if let Some(extra) = cell.zerowidth() {
            out.extend(extra);
        }
    }
    out
}

fn color_label(color: Color) -> String {
    match color {
        Color::Named(named) => format!("{named:?}"),
        Color::Spec(rgb) => format!("#{:02x}{:02x}{:02x}", rgb.r, rgb.g, rgb.b),
        Color::Indexed(index) => format!("indexed:{index}"),
    }
}

fn row_wraps(grid: &alacritty_terminal::grid::Grid<Cell>, line: Line, columns: usize) -> bool {
    columns > 0
        && grid[line][Column(columns - 1)]
            .flags
            .contains(Flags::WRAPLINE)
}

fn row_has_text(grid: &alacritty_terminal::grid::Grid<Cell>, line: Line, columns: usize) -> bool {
    row_wraps(grid, line, columns)
        || (0..columns).any(|i| {
            let cell = &grid[line][Column(i)];
            cell.c != ' '
                && !cell
                    .flags
                    .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
        })
}

fn plain_row(grid: &alacritty_terminal::grid::Grid<Cell>, line: Line, columns: usize) -> String {
    let row = &grid[line];
    let mut out = String::new();

    for i in 0..columns {
        let cell = &row[Column(i)];
        if cell
            .flags
            .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
        {
            continue;
        }
        out.push(cell.c);
        if let Some(extra) = cell.zerowidth() {
            out.extend(extra);
        }
    }

    out.trim_end_matches(' ').to_owned()
}

fn next_char_boundary(value: &str, at_least: usize) -> usize {
    let mut index = at_least.min(value.len());
    while index < value.len() && !value.is_char_boundary(index) {
        index += 1;
    }
    index
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
            sgr.push_str(&format!(
                ";{};5;{}",
                if background { 48 } else { 38 },
                index
            ));
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
    fn repaint_history_is_byte_bounded() {
        let mut screen = Screen::new(24, 80, 50_000);
        // SGR-heavy lines so the full history would far exceed the budget.
        for i in 0..30_000 {
            screen.advance(format!("\x1b[1;31mcolored line number {i}\x1b[0m\r\n").as_bytes());
        }
        let out = screen.repaint(true);

        // Bounded: history budget + screen grid + modes slack.
        assert!(
            out.len() <= REPAINT_HISTORY_BUDGET + 64 * 1024,
            "repaint was {} bytes",
            out.len()
        );

        let s = text(&out);
        // The newest lines survive; the oldest are dropped by the budget.
        assert!(s.contains("colored line number 29999"));
        assert!(!s.contains("colored line number 0\u{1b}"));
    }

    #[test]
    fn repaint_under_budget_is_untruncated() {
        let mut screen = Screen::new(4, 20, 100);
        for i in 0..10 {
            screen.advance(format!("line-{i}\r\n").as_bytes());
        }
        let out = text(&screen.repaint(true));
        assert!(out.contains("line-0"));
        assert!(out.contains("line-9"));
    }

    #[test]
    fn screen_only_repaint_excludes_scrollback_but_keeps_the_viewport() {
        let mut screen = Screen::new(3, 20, 100);
        for i in 0..10 {
            screen.advance(format!("history-{i}\r\n").as_bytes());
        }
        screen.advance(b"visible-marker");

        let out = text(&screen.repaint_with_history(true, 0));

        assert!(!out.contains("history-0"));
        assert!(out.contains("visible-marker"));
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
        assert!(
            out[a..].contains("\r\n"),
            "hard-break mode must keep row newlines"
        );
    }

    #[test]
    fn resize_is_reflected() {
        let mut screen = Screen::new(24, 80, 10);
        screen.resize(30, 100);
        screen.advance(b"after resize");
        let out = text(&screen.repaint(true));
        assert!(out.contains("after resize"));
    }

    #[test]
    fn text_snapshot_joins_wraps_and_excludes_ansi() {
        let mut screen = Screen::new(5, 10, 50);
        screen.advance(b"\x1b[31mABCDEFGHIJKLMNOPQRSTUVWXY\x1b[0m\r\nready");
        let snapshot = screen.text_snapshot(20, 128 * 1024);

        assert_eq!(snapshot.mode, "normal");
        assert!(snapshot
            .lines
            .iter()
            .any(|line| line == "ABCDEFGHIJKLMNOPQRSTUVWXY"));
        assert!(snapshot.lines.iter().any(|line| line == "ready"));
        assert!(!snapshot.lines.join("\n").contains('\x1b'));
    }

    #[test]
    fn text_snapshot_returns_requested_tail_and_reports_truncation() {
        let mut screen = Screen::new(3, 20, 50);
        for i in 0..12 {
            screen.advance(format!("line-{i}\r\n").as_bytes());
        }
        let snapshot = screen.text_snapshot(3, 128 * 1024);

        assert_eq!(snapshot.lines.len(), 3);
        assert!(snapshot.lines.join("\n").contains("line-11"));
        assert!(snapshot.cached_line_count > snapshot.lines.len());
        assert!(snapshot.truncated);
    }

    #[test]
    fn text_snapshot_reports_alternate_screen() {
        let mut screen = Screen::new(4, 20, 50);
        screen.advance(
            b"old\r\n\x1b[?1049h\x1b[?1h\x1b[?2004h\x1b[48;5;236mTUI screen\x1b[0m\r\n\x1b[7;1mSelected option   \x1b[0m",
        );
        let snapshot = screen.text_snapshot(20, 128 * 1024);

        assert_eq!(snapshot.mode, "alternate");
        assert!(snapshot.lines.join("\n").contains("TUI screen"));
        assert!(!snapshot.lines.join("\n").contains("old"));
        assert!(snapshot.input_modes.application_cursor);
        assert!(snapshot.input_modes.bracketed_paste);
        assert!(!snapshot.highlights_truncated);
        assert!(snapshot
            .highlighted_ranges
            .iter()
            .any(|range| { range.text == "TUI screen" && range.background == "indexed:236" }));
        assert!(snapshot
            .highlighted_ranges
            .iter()
            .any(|range| { range.text == "Selected option" && range.inverse && range.bold }));
    }

    #[test]
    fn text_snapshot_caps_a_single_very_long_logical_line() {
        let mut screen = Screen::new(3, 20, 100);
        screen.advance("界".repeat(2_000).as_bytes());
        let snapshot = screen.text_snapshot(0, 257);
        let bytes: usize = snapshot.lines.iter().map(String::len).sum();

        assert!(bytes <= 257);
        assert!(snapshot.truncated);
        assert!(snapshot.lines.join("").chars().all(|ch| ch == '界'));
    }
}

/// Takeover reflow (PTY size ownership): when a claim resizes the grid, the
/// embedded alacritty terminal reflows screen AND scrollback (`Term::resize`
/// passes reflow=true for the normal buffer), and the soft-wrap snapshot must
/// reflect the post-reflow logical lines — soft-wrapped history joined so the
/// receiving xterm re-wraps at its own width, hard newlines preserved.
#[cfg(test)]
mod takeover_reflow_tests {
    use super::*;

    fn text(bytes: &[u8]) -> String {
        String::from_utf8_lossy(bytes).into_owned()
    }

    /// Narrow→wide (phone→desktop takeover): a line soft-wrapped at phone
    /// width must come back as ONE contiguous line in the snapshot.
    #[test]
    fn narrow_to_wide_takeover_rejoins_soft_wrapped_line() {
        let mut screen = Screen::new(10, 45, 1000);
        let long: String = (0..150).map(|_| 'X').collect();
        screen.advance(format!("START{long}END\r\nprompt$ ").as_bytes());
        screen.resize(10, 200);
        let out = text(&screen.repaint(true));
        assert!(
            out.contains(&format!("START{long}END")),
            "soft-wrapped line must rejoin after widening: {out:?}"
        );
    }

    /// Same, but with the long line deep in SCROLLBACK — reflow must cover
    /// history, not just the visible screen.
    #[test]
    fn narrow_to_wide_takeover_reflows_scrollback_history() {
        let mut screen = Screen::new(6, 45, 1000);
        let long: String = (0..150).map(|_| 'X').collect();
        screen.advance(format!("START{long}END").as_bytes());
        for i in 0..30 {
            screen.advance(format!("\r\nfiller-{i}").as_bytes());
        }
        screen.resize(6, 200);
        let out = text(&screen.repaint(true));
        assert!(
            out.contains(&format!("START{long}END")),
            "history line must rejoin after widening: {out:?}"
        );
        // Hard-wrapped filler lines keep their breaks.
        assert!(out.contains("filler-0"));
        assert!(
            !out.contains("filler-0filler-1"),
            "hard newlines must survive"
        );
    }

    /// Wide→narrow (desktop→phone takeover): a desktop-width line re-wraps
    /// into soft segments with no content loss and NO hard breaks between
    /// the segments (the receiving xterm rebuilds the logical line).
    #[test]
    fn wide_to_narrow_takeover_rewraps_without_loss_or_hard_breaks() {
        let mut screen = Screen::new(10, 200, 1000);
        let long: String = (0..150).map(|_| 'X').collect();
        screen.advance(format!("START{long}END\r\nprompt$ ").as_bytes());
        screen.resize(10, 45);
        let out = text(&screen.repaint(true));
        let needle = format!("START{long}END");
        assert!(
            out.contains(&needle),
            "soft-wrapped segments must be contiguous (no \\r\\n baked in): {out:?}"
        );
    }

    /// Full ownership ping-pong (wide → narrow → wide again) round-trips the
    /// logical line: alacritty's shrink marks WRAPLINE rows the grow rejoins.
    #[test]
    fn takeover_pingpong_roundtrips_logical_lines() {
        let mut screen = Screen::new(6, 200, 1000);
        let long: String = (0..150).map(|_| 'X').collect();
        screen.advance(format!("START{long}END").as_bytes());
        for i in 0..30 {
            screen.advance(format!("\r\nfiller-{i}").as_bytes());
        }
        screen.resize(6, 45);
        screen.resize(6, 200);
        let out = text(&screen.repaint(true));
        assert!(
            out.contains(&format!("START{long}END")),
            "ping-pong must round-trip the logical line: {out:?}"
        );
    }

    /// CJK wide chars sitting exactly on the wrap boundary (odd column count
    /// forces a leading-wide-char-spacer wrap) must survive narrow→wide
    /// re-join: every codepoint exactly once, in order, no split chars.
    #[test]
    fn cjk_at_wrap_boundary_survives_narrow_to_wide() {
        // 41 cols: 20 double-width chars fill 40 columns, the 21st cannot
        // fit in the last column — alacritty wraps it with a spacer cell.
        let mut screen = Screen::new(8, 41, 1000);
        let cjk: String = "汉字宽度测试".chars().cycle().take(30).collect();
        screen.advance(format!("前{cjk}后\r\nprompt$ ").as_bytes());
        screen.resize(8, 200);
        let out = text(&screen.repaint(true));
        assert!(
            out.contains(&format!("前{cjk}后")),
            "CJK line must rejoin contiguously after widening: {out:?}"
        );
        for ch in ['前', '后'] {
            assert_eq!(
                out.matches(ch).count(),
                1,
                "codepoint {ch} must appear exactly once"
            );
        }
    }

    /// CJK the other way (wide→narrow onto an odd width): re-wrapped
    /// segments stay joinable and no codepoint is lost or duplicated.
    #[test]
    fn cjk_at_wrap_boundary_survives_wide_to_narrow() {
        let mut screen = Screen::new(8, 200, 1000);
        let cjk: String = "汉字宽度测试".chars().cycle().take(30).collect();
        screen.advance(format!("前{cjk}后\r\nprompt$ ").as_bytes());
        screen.resize(8, 41);
        let out = text(&screen.repaint(true));
        for ch in ['前', '后'] {
            assert_eq!(
                out.matches(ch).count(),
                1,
                "codepoint {ch} must appear exactly once"
            );
        }
        // Soft segments carry no \r\n between them (spacer cells at the
        // wrap boundary are skipped, not rendered), so the whole logical
        // line stays contiguous in the byte stream.
        assert!(
            out.contains(&format!("前{cjk}后")),
            "CJK soft segments must not be separated by hard breaks: {out:?}"
        );
    }
}
