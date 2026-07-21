//! Server-side terminal emulation (the tmux/zellij model).
//!
//! Every byte the PTY produces is fed into a headless alacritty terminal,
//! which maintains the screen grid, scrollback and terminal modes. On attach
//! we synthesize a bounded repaint — history tail, current screen, cursor,
//! modes — instead of replaying the raw byte history, so attaching is O(grid)
//! regardless of how much output the session ever produced.

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::{Dimensions, Grid};
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::{Cell, Flags, Hyperlink};
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{
    CharsetIndex, Color, CursorShape, Handler, NamedColor, NamedPrivateMode, PrivateMode,
    Processor, StandardCharset,
};
use serde::Serialize;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

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

#[derive(Clone, Default)]
struct TerminalEvents {
    pty_writes: Arc<Mutex<VecDeque<Vec<u8>>>>,
}

impl EventListener for TerminalEvents {
    fn send_event(&self, event: Event) {
        if let Event::PtyWrite(reply) = event {
            self.pty_writes
                .lock()
                .unwrap()
                .push_back(reply.into_bytes());
        }
    }
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
    term: Term<TerminalEvents>,
    parser: Processor,
    scroll_tracker: ScrollTracker,
    scroll_parser: Processor,
    alt_tracker: AltTracker,
    alt_parser: alacritty_terminal::vte::Parser,
    normal_grid: Grid<Cell>,
    pty_writes: Arc<Mutex<VecDeque<Vec<u8>>>>,
}

/// Alacritty keeps DECSTBM private to `Term`, and RIS/resize reset it without
/// exposing a getter. Keep the same 1-based inclusive coordinates locally so a
/// synthesized repaint can restore the region after its own RIS reset.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ScrollRegion {
    rows: usize,
    top: usize,
    bottom: usize,
}

impl ScrollRegion {
    fn new(rows: usize) -> Self {
        let rows = rows.max(1);
        Self {
            rows,
            top: 1,
            bottom: rows,
        }
    }

    fn reset(&mut self) {
        self.top = 1;
        self.bottom = self.rows;
    }

    fn resize(&mut self, rows: usize) {
        self.rows = rows.max(1);
        self.reset();
    }

    /// Mirrors `Term::set_scrolling_region`: validate before clamping, then
    /// clamp each edge to the current viewport.
    fn set(&mut self, top: usize, bottom: Option<usize>) {
        let bottom = bottom.unwrap_or(self.rows);
        if top >= bottom {
            return;
        }

        let top = top.saturating_sub(1).min(self.rows.saturating_sub(1)) + 1;
        let bottom = bottom.clamp(1, self.rows);
        if top >= bottom {
            self.reset();
        } else {
            self.top = top;
            self.bottom = bottom;
        }
    }

    fn is_full(self) -> bool {
        self.top == 1 && self.bottom == self.rows
    }

    /// Return a CUP row (1-based), accounting for DEC origin mode's relative
    /// coordinates. The emulator keeps its cursor inside the region while
    /// origin mode is active; clamp defensively for a malformed/stale state.
    fn cursor_row(self, absolute: i32, origin: bool) -> usize {
        let absolute = absolute.clamp(0, self.rows.saturating_sub(1) as i32);
        if !origin {
            return absolute as usize + 1;
        }

        let top = self.top.saturating_sub(1) as i32;
        let bottom = self.bottom.saturating_sub(1) as i32;
        absolute.clamp(top, bottom).saturating_sub(top) as usize + 1
    }
}

/// Mirrors only the terminal callbacks that affect DECSTBM. A second VTE
/// processor is intentionally used instead of another hand-written ANSI state
/// machine, so split strings, C1 controls, synchronized updates and malformed
/// parameter lists follow exactly the same semantics as the real emulator.
struct ScrollTracker {
    region: ScrollRegion,
    active_charset: CharsetIndex,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AltTransition {
    Enter,
    Exit,
}

#[derive(Default)]
struct AltTracker {
    alt_screen: bool,
    transition: Option<AltTransition>,
}

impl alacritty_terminal::vte::Perform for AltTracker {
    fn csi_dispatch(
        &mut self,
        params: &alacritty_terminal::vte::Params,
        intermediates: &[u8],
        ignore: bool,
        action: char,
    ) {
        if ignore || intermediates != b"?" || !matches!(action, 'h' | 'l') {
            return;
        }

        if !params.into_iter().any(|param| param.first() == Some(&1049)) {
            return;
        }

        let alt_screen = action == 'h';
        if self.alt_screen != alt_screen {
            self.alt_screen = alt_screen;
            self.transition = Some(if alt_screen {
                AltTransition::Enter
            } else {
                AltTransition::Exit
            });
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], ignore: bool, byte: u8) {
        if !ignore && intermediates.is_empty() && byte == b'c' && self.alt_screen {
            self.alt_screen = false;
            self.transition = Some(AltTransition::Exit);
        }
    }

    fn terminated(&self) -> bool {
        self.transition.is_some()
    }
}

impl ScrollTracker {
    fn new(rows: usize) -> Self {
        Self {
            region: ScrollRegion::new(rows),
            active_charset: CharsetIndex::default(),
        }
    }

    fn resize(&mut self, rows: usize) {
        self.region.resize(rows);
    }
}

impl Handler for ScrollTracker {
    fn set_scrolling_region(&mut self, top: usize, bottom: Option<usize>) {
        self.region.set(top, bottom);
    }

    fn reset_state(&mut self) {
        self.region.reset();
        self.active_charset = CharsetIndex::default();
    }

    fn set_private_mode(&mut self, mode: PrivateMode) {
        if mode == NamedPrivateMode::ColumnMode.into() {
            self.region.reset();
        }
    }

    fn unset_private_mode(&mut self, mode: PrivateMode) {
        if mode == NamedPrivateMode::ColumnMode.into() {
            self.region.reset();
        }
    }

    fn set_active_charset(&mut self, index: CharsetIndex) {
        self.active_charset = index;
    }
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
        let events = TerminalEvents::default();
        let term = Term::new(config, &size, events.clone());
        let normal_grid = term.grid().clone();
        Screen {
            term,
            parser: Processor::new(),
            scroll_tracker: ScrollTracker::new(size.lines),
            scroll_parser: Processor::new(),
            alt_tracker: AltTracker::default(),
            alt_parser: alacritty_terminal::vte::Parser::new(),
            normal_grid,
            pty_writes: events.pty_writes,
        }
    }

    pub fn advance(&mut self, bytes: &[u8]) {
        let mut processed = 0;
        while processed < bytes.len() {
            self.alt_tracker.transition = None;
            let consumed = self
                .alt_parser
                .advance_until_terminated(&mut self.alt_tracker, &bytes[processed..]);
            debug_assert!(consumed > 0, "non-empty VTE input must make progress");
            let end = processed + consumed;

            match self.alt_tracker.transition {
                Some(AltTransition::Enter) => {
                    self.parser
                        .advance(&mut self.term, &bytes[processed..end - 1]);
                    self.finish_term_synchronized_update();
                    debug_assert!(!self.term.mode().contains(TermMode::ALT_SCREEN));
                    self.parser.advance(&mut self.term, &bytes[end - 1..end]);
                    debug_assert!(self.term.mode().contains(TermMode::ALT_SCREEN));

                    // Capture the normal buffer after the complete CSI has
                    // run. Parameters preceding 1049 (for example DECOM) can
                    // move its cursor before the swap, so a pre-final clone is
                    // observably stale. Preserve the exact alternate grid
                    // while temporarily exposing the inactive normal grid.
                    let alt_grid = self.term.grid().clone();
                    self.term.swap_alt();
                    self.normal_grid = self.term.grid().clone();
                    self.term.swap_alt();
                    *self.term.grid_mut() = alt_grid;
                }
                Some(AltTransition::Exit) => {
                    self.parser
                        .advance(&mut self.term, &bytes[processed..end - 1]);
                    self.finish_term_synchronized_update();
                    self.parser.advance(&mut self.term, &bytes[end - 1..end]);
                }
                None => self.parser.advance(&mut self.term, &bytes[processed..end]),
            }
            processed = end;
        }

        self.scroll_parser.advance(&mut self.scroll_tracker, bytes);
        debug_assert_eq!(
            self.alt_tracker.alt_screen,
            self.term.mode().contains(TermMode::ALT_SCREEN)
        );
    }

    fn finish_term_synchronized_update(&mut self) {
        if self.parser.sync_bytes_count() > 0 || self.parser.sync_timeout().sync_timeout().is_some()
        {
            self.parser.stop_sync(&mut self.term);
        }
    }

    /// Materialize a synchronized-update block before taking a repaint. The
    /// holder only calls `advance` with complete ANSI/UTF-8 tokens, so ending
    /// the block here leaves both the grid and parser at a snapshot-safe
    /// boundary even when an application has not emitted `?2026l` yet.
    pub fn finish_synchronized_update(&mut self) {
        self.finish_term_synchronized_update();
        if self.scroll_parser.sync_bytes_count() > 0
            || self.scroll_parser.sync_timeout().sync_timeout().is_some()
        {
            self.scroll_parser.stop_sync(&mut self.scroll_tracker);
        }
    }

    pub fn take_pty_writes(&self) -> Vec<Vec<u8>> {
        self.pty_writes.lock().unwrap().drain(..).collect()
    }

    pub fn columns(&self) -> usize {
        self.term.grid().columns()
    }

    pub fn resize(&mut self, rows: u16, cols: u16) {
        let rows = rows.max(1) as usize;
        let cols = cols.max(1) as usize;
        let changed = self.term.grid().screen_lines() != rows || self.term.grid().columns() != cols;
        self.term.resize(Size {
            lines: rows,
            columns: cols,
        });
        if changed {
            self.scroll_tracker.resize(rows);
            if self.term.mode().contains(TermMode::ALT_SCREEN) {
                self.normal_grid.resize(true, rows, cols);
            }
        }
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
        let mut out: Vec<u8> = Vec::with_capacity(64 * 1024);

        out.extend_from_slice(b"\x1bc");
        render_palette(&mut out, term);

        let alt = mode.contains(TermMode::ALT_SCREEN);
        if alt {
            // RIS resets both buffers. Rebuild the inactive normal grid first,
            // including its cursor protocol state, so a later 1049l returns to
            // the same shell rather than an empty screen.
            render_grid(&mut out, &self.normal_grid, soft_wrap, history_budget, true);
            render_cursor_state(
                &mut out,
                &self.normal_grid,
                &self.normal_grid.cursor,
                ScrollRegion::new(self.normal_grid.screen_lines()),
                false,
            );
            out.extend_from_slice(b"\x1b[?1049h");
            // The alternate cursor inherits the primary cursor on entry.
            // Return to a known rendering state before painting row zero.
            out.extend_from_slice(b"\x1b[0m\x1b]8;;\x1b\\\x0f\x1b(B\x1b[H");
        }

        render_grid(&mut out, grid, soft_wrap, history_budget, !alt);

        // DECSTBM homes the cursor. Restore it with DECOM still disabled, so
        // even a saved cursor outside the current region can be addressed.
        let scroll_region = self.scroll_tracker.region;
        if !scroll_region.is_full() {
            out.extend_from_slice(
                format!("\x1b[{};{}r", scroll_region.top, scroll_region.bottom).as_bytes(),
            );
        }

        render_cursor_state(&mut out, grid, &grid.saved_cursor, scroll_region, false);
        out.extend_from_slice(b"\x1b7");

        render_modes(&mut out, term, &mode);
        if mode.contains(TermMode::ORIGIN) {
            out.extend_from_slice(b"\x1b[?6h");
        }

        render_cursor_state(
            &mut out,
            grid,
            &grid.cursor,
            scroll_region,
            mode.contains(TermMode::ORIGIN),
        );
        render_active_charset(&mut out, self.scroll_tracker.active_charset);
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

fn render_grid(
    out: &mut Vec<u8>,
    grid: &Grid<Cell>,
    soft_wrap: bool,
    history_budget: usize,
    include_history: bool,
) {
    let columns = grid.columns();
    let mut pen = Pen::default();
    let mut previous_wrapped = false;

    if include_history {
        // The repaint is parsed synchronously on the client's main thread, so
        // cap history by rendered bytes rather than retained grid rows.
        let history = grid.history_size();
        let mut first = history;
        let mut used = 0usize;
        for i in (0..history).rev() {
            let line = Line(i as i32 - history as i32);
            let mut scratch: Vec<u8> = Vec::with_capacity(64);
            let mut scratch_pen = Pen::default();
            let previous_wrapped =
                soft_wrap && i > 0 && row_wraps(grid, Line(i as i32 - 1 - history as i32), columns);
            let wrapped = render_grid_row(
                &mut scratch,
                &mut scratch_pen,
                grid,
                line,
                columns,
                soft_wrap,
                previous_wrapped,
            );
            let row_len = scratch.len() + if wrapped { 0 } else { 2 };
            if used + row_len > history_budget {
                break;
            }
            used += row_len;
            first = i;
        }

        // Never start mid-logical-line; the leading continuation would have
        // inherited rendition and wrapping state from a row we did not emit.
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
            previous_wrapped = render_grid_row(
                out,
                &mut pen,
                grid,
                line,
                columns,
                soft_wrap,
                previous_wrapped,
            );
            if !previous_wrapped {
                out.extend_from_slice(b"\r\n");
            }
        }
    }

    render_screen_rows(out, &mut pen, grid, columns, soft_wrap, previous_wrapped);
}

fn render_grid_row(
    out: &mut Vec<u8>,
    pen: &mut Pen,
    grid: &Grid<Cell>,
    line: Line,
    columns: usize,
    soft_wrap: bool,
    previous_wrapped: bool,
) -> bool {
    if previous_wrapped && render_row_end(grid, line, columns, soft_wrap) == 0 {
        // A printable byte is required to materialize the pending wrap into an
        // otherwise empty continuation row. CSI EL/CR would cancel it and
        // collapse every following physical row upward.
        pen.reset(out);
        pen.apply(out, &grid[line][Column(0)]);
        out.push(b' ');
    }

    render_row(out, pen, grid, line, columns, soft_wrap)
}

fn render_row_end(grid: &Grid<Cell>, line: Line, columns: usize, soft_wrap: bool) -> usize {
    if soft_wrap && row_wraps(grid, line, columns) {
        return columns;
    }

    let row = &grid[line];
    for i in (0..columns).rev() {
        let cell = &row[Column(i)];
        if cell.c != ' '
            || cell.bg != Color::Named(NamedColor::Background)
            || cell.hyperlink().is_some()
            || cell
                .flags
                .intersects(Flags::INVERSE | Flags::ALL_UNDERLINES | Flags::STRIKEOUT)
        {
            return i + 1;
        }
    }

    0
}

fn render_screen_rows(
    out: &mut Vec<u8>,
    pen: &mut Pen,
    grid: &Grid<Cell>,
    columns: usize,
    soft_wrap: bool,
    mut previous_wrapped: bool,
) {
    for i in 0..grid.screen_lines() {
        previous_wrapped = render_grid_row(
            out,
            pen,
            grid,
            Line(i as i32),
            columns,
            soft_wrap,
            previous_wrapped,
        );
        if !previous_wrapped && i + 1 < grid.screen_lines() {
            out.extend_from_slice(b"\r\n");
        }
    }
}

fn render_cursor_state(
    out: &mut Vec<u8>,
    grid: &Grid<Cell>,
    cursor: &alacritty_terminal::grid::Cursor<Cell>,
    scroll_region: ScrollRegion,
    origin: bool,
) {
    render_cursor_position(
        out,
        cursor.point.line.0,
        cursor.point.column.0,
        scroll_region,
        origin,
    );

    if cursor.input_needs_wrap {
        render_pending_wrap(out, grid, cursor, scroll_region, origin);
    }

    render_charsets(out, &cursor.charsets);
    render_rendition(out, &cursor.template);
}

fn render_pending_wrap(
    out: &mut Vec<u8>,
    grid: &Grid<Cell>,
    cursor: &alacritty_terminal::grid::Cursor<Cell>,
    scroll_region: ScrollRegion,
    origin: bool,
) {
    let mut column = cursor.point.column;
    let cursor_cell = &grid[cursor.point];
    if cursor_cell.flags.contains(Flags::WIDE_CHAR_SPACER) && column > Column(0) {
        column -= 1;
    }

    render_cursor_position(out, cursor.point.line.0, column.0, scroll_region, origin);
    // Ensure an ASCII byte is not remapped while reproducing the cell which
    // originally put the cursor into xterm's pending-wrap state.
    out.extend_from_slice(b"\x0f\x1b(B");
    let cell = &grid[cursor.point.line][column];
    render_rendition(out, cell);
    let mut buffer = [0; 4];
    out.extend_from_slice(cell.c.encode_utf8(&mut buffer).as_bytes());
    if let Some(extra) = cell.zerowidth() {
        for character in extra {
            out.extend_from_slice(character.encode_utf8(&mut buffer).as_bytes());
        }
    }
}

fn render_cursor_position(
    out: &mut Vec<u8>,
    line: i32,
    column: usize,
    scroll_region: ScrollRegion,
    origin: bool,
) {
    let row = scroll_region.cursor_row(line, origin);
    out.extend_from_slice(format!("\x1b[{row};{}H", column + 1).as_bytes());
}

fn render_charsets(out: &mut Vec<u8>, charsets: &alacritty_terminal::grid::Charsets) {
    for (index, intermediate) in [
        (CharsetIndex::G0, b'('),
        (CharsetIndex::G1, b')'),
        (CharsetIndex::G2, b'*'),
        (CharsetIndex::G3, b'+'),
    ] {
        let final_byte = match charsets[index] {
            StandardCharset::Ascii => b'B',
            StandardCharset::SpecialCharacterAndLineDrawing => b'0',
        };
        out.extend_from_slice(&[0x1b, intermediate, final_byte]);
    }
}

fn render_active_charset(out: &mut Vec<u8>, active: CharsetIndex) {
    match active {
        CharsetIndex::G0 => out.push(0x0f),
        CharsetIndex::G1 => out.push(0x0e),
        // Alacritty's VTE currently exposes no escape dispatch which selects
        // G2/G3, so the tracker cannot reach these variants.
        CharsetIndex::G2 | CharsetIndex::G3 => {}
    }
}

fn render_rendition(out: &mut Vec<u8>, cell: &Cell) {
    out.extend_from_slice(b"\x1b[0m");
    Pen::default().apply_style(out, cell);
    let hyperlink = cell.hyperlink();
    render_hyperlink(out, hyperlink.as_ref());
}

fn render_hyperlink(out: &mut Vec<u8>, hyperlink: Option<&Hyperlink>) {
    if let Some(link) = hyperlink {
        out.extend_from_slice(format!("\x1b]8;id={};{}\x1b\\", link.id(), link.uri()).as_bytes());
    } else {
        out.extend_from_slice(b"\x1b]8;;\x1b\\");
    }
}

fn render_palette(out: &mut Vec<u8>, term: &Term<TerminalEvents>) {
    for index in 0..alacritty_terminal::term::color::COUNT {
        let Some(color) = term.colors()[index] else {
            continue;
        };
        if (NamedColor::Foreground as usize..=NamedColor::Cursor as usize).contains(&index) {
            let code = 10 + index - NamedColor::Foreground as usize;
            out.extend_from_slice(
                format!(
                    "\x1b]{code};rgb:{:02x}/{:02x}/{:02x}\x1b\\",
                    color.r, color.g, color.b
                )
                .as_bytes(),
            );
        } else {
            out.extend_from_slice(
                format!(
                    "\x1b]4;{index};rgb:{:02x}/{:02x}/{:02x}\x1b\\",
                    color.r, color.g, color.b
                )
                .as_bytes(),
            );
        }
    }
}

fn render_modes(out: &mut Vec<u8>, term: &Term<TerminalEvents>, mode: &TermMode) {
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

    // RIS enables line wrapping. Restore the disabled state after the
    // synthesized rows and absolute cursor position have been emitted, so
    // those rows are reconstructed independently of the saved mode.
    if !mode.contains(TermMode::LINE_WRAP) {
        out.extend_from_slice(b"\x1b[?7l");
    }

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
    let wrapped = soft_wrap && row_wraps(grid, line, columns);

    // Trim trailing cells that would render as nothing (never on wrapped
    // rows: auto-wrap needs the full width written out).
    let end = render_row_end(grid, line, columns, soft_wrap);

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
        pen.reset(out);
        out.extend_from_slice(b"\x1b[K");
    }

    wrapped
}

/// Tracks active SGR and OSC 8 state, emitting updates only on change.
struct Pen {
    fg: Color,
    bg: Color,
    flags: Flags,
    underline_color: Option<Color>,
    hyperlink: Option<Hyperlink>,
}

impl Default for Pen {
    fn default() -> Self {
        Pen {
            fg: Color::Named(NamedColor::Foreground),
            bg: Color::Named(NamedColor::Background),
            flags: Flags::empty(),
            underline_color: None,
            hyperlink: None,
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
        let hyperlink = cell.hyperlink();
        if self.hyperlink != hyperlink {
            render_hyperlink(out, hyperlink.as_ref());
            self.hyperlink = hyperlink;
        }

        self.apply_style(out, cell);
    }

    fn apply_style(&mut self, out: &mut Vec<u8>, cell: &Cell) {
        let flags = cell.flags & STYLE_FLAGS;
        let underline_color = cell.underline_color();
        if self.fg == cell.fg
            && self.bg == cell.bg
            && self.flags == flags
            && self.underline_color == underline_color
        {
            return;
        }
        self.fg = cell.fg;
        self.bg = cell.bg;
        self.flags = flags;
        self.underline_color = underline_color;

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
        if flags.contains(Flags::DOUBLE_UNDERLINE) {
            sgr.push_str(";4:2");
        } else if flags.contains(Flags::UNDERCURL) {
            sgr.push_str(";4:3");
        } else if flags.contains(Flags::DOTTED_UNDERLINE) {
            sgr.push_str(";4:4");
        } else if flags.contains(Flags::DASHED_UNDERLINE) {
            sgr.push_str(";4:5");
        } else if flags.contains(Flags::UNDERLINE) {
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
        if let Some(color) = underline_color {
            push_underline_color(&mut sgr, color);
        }
        sgr.push('m');
        out.extend_from_slice(sgr.as_bytes());
    }

    fn reset(&mut self, out: &mut Vec<u8>) {
        out.extend_from_slice(b"\x1b[0m");
        if self.hyperlink.is_some() {
            render_hyperlink(out, None);
        }
        *self = Self::default();
    }
}

fn push_underline_color(sgr: &mut String, color: Color) {
    match color {
        Color::Indexed(index) => sgr.push_str(&format!(";58;5;{index}")),
        Color::Spec(rgb) => sgr.push_str(&format!(";58;2;{};{};{}", rgb.r, rgb.g, rgb.b)),
        Color::Named(named) => {
            let index = named as usize;
            if index < 16 {
                sgr.push_str(&format!(";58;5;{index}"));
            }
        }
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
    fn repaint_restores_hyperlinks_on_rendered_cells() {
        let mut original = Screen::new(4, 30, 100);
        original.advance(
            b"\x1b]8;id=docs;https://example.test/docs\x1b\\linked\
              \x1b]8;;\x1b\\ plain \
              \x1b]8;id=issue;https://example.test/issues/1\x1b\\issue\
              \x1b]8;;\x1b\\",
        );
        assert!(original.term.grid()[Line(0)][Column(0)]
            .hyperlink()
            .is_some());
        assert!(original.term.grid()[Line(0)][Column(6)]
            .hyperlink()
            .is_none());

        let mut restored = Screen::new(4, 30, 100);
        restored.advance(&original.repaint(true));

        for column in 0..original.term.grid().columns() {
            assert_eq!(
                restored.term.grid()[Line(0)][Column(column)],
                original.term.grid()[Line(0)][Column(column)]
            );
        }
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
    fn repaint_restores_line_wrap_and_origin_modes() {
        let mut screen = Screen::new(10, 40, 100);
        // These modes differ from the default RIS state. A repaint must
        // preserve them for the next command even though it renders rows
        // with the reset terminal state first.
        screen.advance(b"\x1b[?7l\x1b[?6hTUI");
        let out = text(&screen.repaint(true));

        assert!(out.contains("\x1b[?7l"));
        assert!(out.contains("\x1b[?6h"));
        let origin = out.find("\x1b[?6h").unwrap();
        let cursor = out.find("\x1b[1;4H").unwrap();
        assert!(origin < cursor, "origin mode must precede the final CUP");

        // Parse the synthesized stream through a fresh emulator as a proxy
        // for the browser terminal. Both the saved modes and cursor point
        // must survive the RIS + mode restoration sequence.
        let mut restored = Screen::new(10, 40, 100);
        restored.advance(out.as_bytes());
        assert!(restored.term.mode().contains(TermMode::ORIGIN));
        assert!(!restored.term.mode().contains(TermMode::LINE_WRAP));
        assert_eq!(
            restored.term.grid().cursor.point,
            screen.term.grid().cursor.point
        );
    }

    #[test]
    fn repaint_restores_a_non_default_decstbm_region() {
        let mut screen = Screen::new(10, 40, 100);
        screen.advance(b"\x1b[2;9r\x1b[4;7Hregion");

        let out = text(&screen.repaint(true));

        assert!(
            out.contains("\x1b[2;9r"),
            "repaint must restore the saved DECSTBM region"
        );
    }

    #[test]
    fn repaint_normalizes_default_and_omitted_decstbm_parameters() {
        let mut screen = Screen::new(10, 40, 100);
        screen.advance(b"\x1b[3;rmarker");

        let out = text(&screen.repaint(true));

        // VTE treats an omitted/zero bottom parameter as the last row. The
        // synthesized stream may normalize the spelling, but not the region.
        assert!(out.contains("\x1b[3;10r"));

        screen.advance(b"\x1b[r");
        let reset = text(&screen.repaint(true));
        assert!(!reset.contains("\x1b[3;10r"));
    }

    #[test]
    fn split_seven_bit_decstbm_is_tracked_across_reads() {
        let mut screen = Screen::new(10, 40, 100);
        screen.advance(b"\x1b[2;");
        screen.advance(b"9r");

        assert!(text(&screen.repaint(true)).contains("\x1b[2;9r"));
    }

    #[test]
    fn ris_and_resize_clear_the_tracked_decstbm_region() {
        let mut screen = Screen::new(10, 40, 100);
        screen.advance(b"\x1b[2;9r");
        screen.advance(b"\x1bc");
        assert!(!text(&screen.repaint(true)).contains("\x1b[2;9r"));

        screen.advance(b"\x1b[2;9r");
        screen.resize(8, 40);
        assert!(!text(&screen.repaint(true)).contains("\x1b[2;9r"));
    }

    #[test]
    fn a_same_dimension_resize_does_not_clear_decstbm() {
        let mut screen = Screen::new(10, 40, 100);
        screen.advance(b"\x1b[2;9r");
        screen.resize(10, 40);

        assert!(text(&screen.repaint(true)).contains("\x1b[2;9r"));
    }

    #[test]
    fn deccolm_resets_the_tracked_decstbm_region() {
        let mut screen = Screen::new(10, 40, 100);
        screen.advance(b"\x1b[2;9r\x1b[?3h");

        assert!(!text(&screen.repaint(true)).contains("\x1b[2;9r"));
    }

    #[test]
    fn alternate_screen_keeps_the_active_decstbm_region() {
        let mut screen = Screen::new(10, 40, 100);
        screen.advance(b"\x1b[?1049h\x1b[3;8r\x1b[?6hALT");

        let out = text(&screen.repaint(true));

        assert!(out.contains("\x1b[3;8r"));
        let region = out.find("\x1b[3;8r").unwrap();
        let origin = out.find("\x1b[?6h").unwrap();
        let cursor = out.find("\x1b[1;4H").unwrap();
        assert!(region < origin && origin < cursor);
        let mut restored = Screen::new(10, 40, 100);
        restored.advance(out.as_bytes());
        assert!(restored.term.mode().contains(TermMode::ALT_SCREEN));
        assert!(restored.term.mode().contains(TermMode::ORIGIN));
        assert_eq!(
            restored.term.grid().cursor.point,
            screen.term.grid().cursor.point
        );
    }

    #[test]
    fn decstbm_is_shared_across_alacritty_alt_buffer_swaps() {
        let mut screen = Screen::new(10, 40, 100);
        screen.advance(b"\x1b[2;9r\x1b[?1049h");
        assert!(text(&screen.repaint(true)).contains("\x1b[2;9r"));

        screen.advance(b"\x1b[3;8r\x1b[?1049l");
        assert!(text(&screen.repaint(true)).contains("\x1b[3;8r"));
    }

    #[test]
    fn repaint_boundary_finishes_a_synchronized_update() {
        let mut screen = Screen::new(10, 40, 100);
        screen.advance(b"\x1b[?2026hSYNC-MARKER");

        assert!(!text(&screen.repaint(true)).contains("SYNC-MARKER"));
        screen.finish_synchronized_update();
        assert!(text(&screen.repaint(true)).contains("SYNC-MARKER"));

        // The parser is back in ordinary ground mode; later output must not
        // stay trapped waiting for an ESU sequence the client never needs.
        screen.advance(b"-AFTER");
        assert!(text(&screen.repaint(true)).contains("SYNC-MARKER-AFTER"));
    }

    #[test]
    fn synchronized_decstbm_is_materialized_with_the_grid() {
        let mut screen = Screen::new(10, 40, 100);
        screen.advance(b"\x1b[?2026h\x1b[2;9r");

        assert!(!text(&screen.repaint(true)).contains("\x1b[2;9r"));
        screen.finish_synchronized_update();
        assert!(text(&screen.repaint(true)).contains("\x1b[2;9r"));
    }

    #[test]
    fn hostile_decstbm_is_normalized_before_decom_repaint() {
        let mut screen = Screen::new(10, 40, 100);
        screen.advance(b"\x1b[999;1000r\x1b[?6h");

        let repaint = screen.repaint(true);

        assert!(screen.scroll_tracker.region.is_full());
        let mut restored = Screen::new(10, 40, 100);
        restored.advance(&repaint);
        assert!(restored.term.mode().contains(TermMode::ORIGIN));
    }

    #[test]
    fn repaint_preserves_current_pen_saved_cursor_and_charset_behavior() {
        let mut original = Screen::new(8, 20, 100);
        original.advance(
            b"\x1b]4;1;rgb:12/34/56\x1b\\\
              \x1b[2;3H\x1b[31;44;1;4:2;58;2;9;8;7m\
              \x1b]8;id=saved;https://saved.example\x1b\\\x1b)0\x0e\x1b7\
              \x1b[5;6H\x1b[32;45;3;4:3;58;5;123m\
              \x1b]8;id=current;https://current.example\x1b\\\x1b)0\x0e",
        );

        let mut restored = Screen::new(8, 20, 100);
        restored.advance(&original.repaint(true));

        // The first byte uses the current G1 line-drawing charset and pen.
        // DECRC then restores the independently saved cursor, pen and charset.
        let follow_up = b"q\x1b8q";
        original.advance(follow_up);
        restored.advance(follow_up);

        assert_eq!(restored.term.grid().cursor, original.term.grid().cursor);
        assert_eq!(
            restored.term.grid().saved_cursor,
            original.term.grid().saved_cursor
        );
        assert_eq!(
            restored.term.grid()[Line(4)][Column(5)],
            original.term.grid()[Line(4)][Column(5)]
        );
        assert_eq!(
            restored.term.grid()[Line(1)][Column(2)],
            original.term.grid()[Line(1)][Column(2)]
        );
        assert_eq!(original.term.grid()[Line(4)][Column(5)].c, '─');
        assert_eq!(original.term.grid()[Line(1)][Column(2)].c, '─');
        assert_eq!(restored.term.colors()[1], original.term.colors()[1]);
    }

    #[test]
    fn alt_repaint_restores_the_normal_buffer_for_later_exit() {
        let mut original = Screen::new(8, 20, 100);
        original.advance(b"NORMAL\x1b[?10");
        original.advance(b"49hALT");

        let mut restored = Screen::new(8, 20, 100);
        restored.advance(&original.repaint(true));
        let follow_up = b"\x1b[?1049l-NEXT";
        original.advance(follow_up);
        restored.advance(follow_up);

        assert!(!restored.term.mode().contains(TermMode::ALT_SCREEN));
        assert_eq!(restored.term.grid().cursor, original.term.grid().cursor);
        for line in 0..original.term.grid().screen_lines() {
            for column in 0..original.term.grid().columns() {
                assert_eq!(
                    restored.term.grid()[Line(line as i32)][Column(column)],
                    original.term.grid()[Line(line as i32)][Column(column)]
                );
            }
        }
    }

    #[test]
    fn alt_entry_captures_modes_preceding_1049_in_the_same_csi() {
        let mut original = Screen::new(8, 20, 100);
        original.advance(b"NORMAL\x1b[5;7H\x1b[?6;10");
        original.advance(b"49hALT");

        let mut restored = Screen::new(8, 20, 100);
        restored.advance(&original.repaint(true));
        let follow_up = b"\x1b[?1049l-NEXT";
        original.advance(follow_up);
        restored.advance(follow_up);

        assert_eq!(restored.term.grid().cursor, original.term.grid().cursor);
        for line in 0..original.term.grid().screen_lines() {
            for column in 0..original.term.grid().columns() {
                assert_eq!(
                    restored.term.grid()[Line(line as i32)][Column(column)],
                    original.term.grid()[Line(line as i32)][Column(column)]
                );
            }
        }
    }

    #[test]
    fn synchronized_multi_alt_transitions_keep_the_latest_normal_grid() {
        let mut original = Screen::new(8, 30, 100);
        original.advance(
            b"BASE\x1b[?2026h-NORMAL\x1b[?1049hALT-ONE\
              \x1b[?1049l-AFTER\x1b[?1049hALT-TWO",
        );
        original.finish_synchronized_update();

        let mut restored = Screen::new(8, 30, 100);
        restored.advance(&original.repaint(true));
        let follow_up = b"\x1b[?1049l-NEXT";
        original.advance(follow_up);
        restored.advance(follow_up);

        assert_eq!(restored.term.grid().cursor, original.term.grid().cursor);
        for line in 0..original.term.grid().screen_lines() {
            for column in 0..original.term.grid().columns() {
                assert_eq!(
                    restored.term.grid()[Line(line as i32)][Column(column)],
                    original.term.grid()[Line(line as i32)][Column(column)]
                );
            }
        }
    }

    #[test]
    fn repaint_preserves_pending_wrap_for_the_next_printable_byte() {
        let mut original = Screen::new(4, 8, 100);
        original.advance(b"\x1b[1;8HX");
        assert!(original.term.grid().cursor.input_needs_wrap);

        let mut restored = Screen::new(4, 8, 100);
        restored.advance(&original.repaint(true));
        assert!(restored.term.grid().cursor.input_needs_wrap);

        original.advance(b"Y");
        restored.advance(b"Y");
        assert_eq!(restored.term.grid().cursor, original.term.grid().cursor);
        assert_eq!(
            restored.term.grid()[Line(1)][Column(0)],
            original.term.grid()[Line(1)][Column(0)]
        );
    }

    #[test]
    fn repaint_keeps_a_blank_soft_wrap_continuation_row() {
        let mut original = Screen::new(4, 5, 100);
        original.advance(b"ABCDE \r\nNEXT");
        assert!(original.term.grid()[Line(0)][Column(4)]
            .flags
            .contains(Flags::WRAPLINE));
        assert_eq!(plain_row(original.term.grid(), Line(1), 5), "");

        let mut restored = Screen::new(4, 5, 100);
        restored.advance(&original.repaint(true));
        original.advance(b"!");
        restored.advance(b"!");

        assert_eq!(restored.term.grid().cursor, original.term.grid().cursor);
        for line in 0..original.term.grid().screen_lines() {
            for column in 0..original.term.grid().columns() {
                assert_eq!(
                    restored.term.grid()[Line(line as i32)][Column(column)],
                    original.term.grid()[Line(line as i32)][Column(column)]
                );
            }
        }
    }

    #[test]
    fn repaint_keeps_a_link_boundary_before_a_blank_wrap_row() {
        let mut original = Screen::new(4, 5, 100);
        original.advance(
            b"\x1b]8;id=wrap;https://example.test/wrap\x1b\\ABCDE\
              \x1b]8;;\x1b\\ \r\nNEXT",
        );

        let mut restored = Screen::new(4, 5, 100);
        restored.advance(&original.repaint(true));
        original.advance(b"!");
        restored.advance(b"!");

        assert_eq!(restored.term.grid().cursor, original.term.grid().cursor);
        for line in 0..original.term.grid().screen_lines() {
            for column in 0..original.term.grid().columns() {
                assert_eq!(
                    restored.term.grid()[Line(line as i32)][Column(column)],
                    original.term.grid()[Line(line as i32)][Column(column)]
                );
            }
        }
    }

    #[test]
    fn repaint_keeps_a_blank_wrap_between_history_and_viewport() {
        let mut original = Screen::new(3, 5, 100);
        original.advance(b"ABCDE \r\nNEXT\r\n");
        assert_eq!(original.term.grid().history_size(), 1);
        assert!(row_wraps(original.term.grid(), Line(-1), 5));
        assert_eq!(plain_row(original.term.grid(), Line(0), 5), "");

        let mut restored = Screen::new(3, 5, 100);
        restored.advance(&original.repaint(true));
        original.advance(b"!");
        restored.advance(b"!");

        assert_eq!(restored.term.grid().cursor, original.term.grid().cursor);
        assert_eq!(
            restored.term.grid().history_size(),
            original.term.grid().history_size()
        );
        for line in -1..original.term.grid().screen_lines() as i32 {
            for column in 0..original.term.grid().columns() {
                assert_eq!(
                    restored.term.grid()[Line(line)][Column(column)],
                    original.term.grid()[Line(line)][Column(column)]
                );
            }
        }
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
