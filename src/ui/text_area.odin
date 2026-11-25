package ui

import "cosmos:font"
import "cosmos:render"
import "base:runtime"
import "core:log"
import "core:math"
import "core:strings"
import "cosmos:textedit"

// A wrapped, multi-line plain-text editor for a short note such as a comment (D-100). The text and its
// caret, selection and undo live in a textedit.Buffer the host owns. Use text_area_horizontal and
// text_area_erase for Left, Right, Backspace and Delete; textedit's own character operations use runes.

// One visual line: the bytes from `start` to `end`. A line the text wraps keeps its trailing spaces and
// the next line starts where it ends; a line a '\n' (or "\r\n") ends stops before it.
Text_Area_Line :: struct {
	start, end: int,
}

// A text area's layout and scroll. Zero is an empty area; `text_area_reset` returns one to that when
// the host puts new text in the buffer, and `text_area_destroy` frees it.
Text_Area :: struct {
	lines:             [dynamic]Text_Area_Line,
	// What `lines` was wrapped for, so a frame with the same text, width and font wraps nothing.
	wrapped:           bool,
	wrapped_revision:  u64,
	wrapped_width:     f32,
	wrapped_size:      f32,
	wrapped_family:    font.Family,
	// How far the text is scrolled up inside the box, in pixels.
	scroll:            f32,
	// Where a run of Up and Down keeps the caret across shorter lines, from the text's left edge; it
	// holds only while the caret is where the last such move left it.
	goal_x:            f32,
	goal_caret:        int,
	goal_revision:     u64,
	goal_set:          bool,
	// The caret and box the scroll last made visible. Scrolling by hand sticks until one of them changes.
	revealed:          bool,
	revealed_caret:    int,
	revealed_revision: u64,
	revealed_height:   f32,
	revealed_width:    f32,
	// A pointer press in the box holds until the host calls `text_area_release`. A double or triple click
	// holds the unit it selected, `unit_from`..`unit_to`, which the drag grows by.
	dragging:          bool,
	unit:              Maybe(textedit.Unit),
	unit_from:         int,
	unit_to:           int,
	caret:             Field_Caret,
}

// A text area, its buffer and the box they fill, as draw and hit tests read it. The box is `rect`, as
// tall as `text_area_height` says; `text` carries the window scale in its size, like Field_Box's.
Text_Area_Box :: struct {
	area:   ^Text_Area,
	buffer: ^textedit.Buffer,
	text:   ^Text,
	rect:   render.Rect,
	scale:  f32,
}

text_area_destroy :: proc(a: ^Text_Area) {
	delete(a.lines)
	a^ = {}
}

// Forgets the layout and the scroll, for when the buffer holds a different text. Keeps the allocation.
text_area_reset :: proc(a: ^Text_Area) {
	lines := a.lines
	clear(&lines)
	a^ = {lines = lines}
}

// Where the caret stands along `row` as area_row_draw sets it: the text between tabs as the font sets it,
// and each tab as the TAB_COLUMNS spaces it spans, as in the diff's code. Without memory it lays out
// nothing.
@(private = "file")
area_row_line :: proc(t: ^Text, row: string) -> Text_Line {
	x := make([dynamic]f32, 0, len(row) + 1, context.temp_allocator)
	tab: f32
	pen: f32
	rest := row
	for {
		end := strings.index_byte(rest, '\t')
		err: runtime.Allocator_Error
		pen, err = line_fill(t, end < 0 ? rest : rest[:end], &x, pen)
		if err != nil {
			log.errorf("ui: laying out a text area row failed: %v", err)
			return {}
		}
		if end < 0 {return {x[:]}}
		if tab == 0 {tab = TAB_COLUMNS * code_space(t)}
		pen += tab
		rest = rest[end + 1:]
	}
}

// Draws one row of the area's text from `x`, leaving the room of each tab it holds empty.
@(private = "file")
area_row_draw :: proc(
	t: ^Text, list: ^render.Draw_List, row: string, x, baseline: f32, color: render.Color,
) -> render.Build_Status {
	x, rest := x, row
	for rest != "" {
		end := strings.index_byte(rest, '\t')
		run := end < 0 ? rest : rest[:end]
		if run != "" {
			if result := draw_text(t, list, run, x, baseline, color); result != .Ok {return result}
			if end >= 0 {x += text_width(t, run)}
		}
		if end < 0 {break}
		x += TAB_COLUMNS * code_space(t)
		rest = rest[end + 1:]
	}
	return .Ok
}

// Wraps the buffer's text to `width` pixels, unless that was already done for this text, width and font.
// Lines break at '\n' (or "\r\n"), and inside a paragraph as area_wrap_paragraph says.
@(private = "file")
area_wrap :: proc(a: ^Text_Area, b: ^textedit.Buffer, t: ^Text, width: f32) {
	if a.wrapped && a.wrapped_revision == b.revision && a.wrapped_width == width &&
	   a.wrapped_size == t.size_px && a.wrapped_family == t.family {
		return
	}
	a.wrapped, a.wrapped_revision, a.wrapped_width = true, b.revision, width
	a.wrapped_size, a.wrapped_family = t.size_px, t.family
	clear(&a.lines)
	s := textedit.to_string(b)
	paragraph := b.floor
	for {
		newline := strings.index_byte(s[paragraph:], '\n')
		end := newline < 0 ? len(s) : paragraph + newline
		if newline > 0 && s[end - 1] == '\r' {end -= 1}
		start := area_wrap_paragraph(a, t, s, paragraph, end, width)
		append(&a.lines, Text_Area_Line{start, end})
		if newline < 0 {return}
		paragraph += newline + 1
	}
}

// Wraps s[from:to], which no line break interrupts, appending every line but its last and returning where
// that one starts. Prefer to break after spaces or tabs; split an oversized word at a grapheme.
// Spaces and tabs after a word stay on its row even if they hang past the width.
@(private = "file")
area_wrap_paragraph :: proc(a: ^Text_Area, t: ^Text, s: string, from, to: int, width: f32) -> int {
	scratch: Shape_Scratch = ---
	starts: [CLIP_BYTES]int = ---
	row, run_end := from, area_run_end(s, from, to)
	tab: f32
	for row < to {
		pen: f32
		last_break := -1
		has_word, wrapped := false, false
		for part := row; part < to; {
			if part == run_end {
				if tab == 0 {tab = TAB_COLUMNS * code_space(t)}
				pen += tab
				part += 1
				if has_word {last_break = part}
				// Any break after consuming a tab is at or after its end: either a saved
				// word break, or the first non-space that did not fit after leading tabs.
				run_end = area_run_end(s, part, to)
				continue
			}
			line := Wrap_Lines{text = t, s = s[:run_end], width = width, line_start = row}
			piece := shape_piece(t, line.s, part, &scratch, starts[:])
			after := pen
			for g in piece.glyphs {after += g.advance}
			fit := len(piece.graphemes)
			if after > width && fit > 0 {fit = wrap_fit(&line, piece, part, pen, after, &scratch)}
			if fit == len(piece.graphemes) && piece.end == to {return row}

			// Only spaces following a word are break opportunities; leading spaces stay together.
			first_word := row - 1
			if !has_word {
				for i in 0 ..< fit {
					if !wrap_is_space(line.s, piece, i) {
						first_word = piece.graphemes[i]
						has_word = true
						break
					}
				}
			}
			if has_word {
				if space := wrap_space(&line, piece, part, pen, fit, &scratch); space > first_word {
					last_break = space + 1
				}
			}
			if fit < len(piece.graphemes) {
				end := last_break > row ? last_break : piece.graphemes[fit]
				append(&a.lines, Text_Area_Line{row, end})
				row, wrapped = end, true
				break
			}
			pen, part = after, piece.end
		}
		if !wrapped {break}
	}
	return row
}

@(private = "file")
area_run_end :: proc(s: string, from, to: int) -> int {
	tab := strings.index_byte(s[from:to], '\t')
	return tab < 0 ? to : from + tab
}

// The padding above and below the lines: what centres one line in a standard field, so a one-line area
// is as tall as a Text_Field.
@(private = "file")
area_pad :: proc(t: ^Text, scale: f32) -> f32 {
	return max(SPACE_1 * scale, (HEIGHT_STANDARD * scale - t.line_height) / 2)
}

// Where the text sits in the box, and the Body text it is drawn with.
@(private = "file")
area_frame :: proc(box: Text_Area_Box) -> (frame: render.Rect, t: Text) {
	t = text_styled(box.text, .Body)
	inset, pad := CONTROL_INSET * box.scale, area_pad(&t, box.scale)
	frame = {
		box.rect.x + inset,
		box.rect.y + pad,
		max(1, box.rect.width - 2 * inset),
		max(t.line_height, box.rect.height - 2 * pad),
	}
	return
}

// The box's lines wrapped for it, which the other queries read.
@(private = "file")
area_laid_out :: proc(box: Text_Area_Box) -> (frame: render.Rect, t: Text) {
	frame, t = area_frame(box)
	area_wrap(box.area, box.buffer, &t, frame.width)
	return
}

// The visual lines of a `width` pixels wide box, wrapped if the text or width changed since last asked.
@(require_results)
text_area_lines :: proc(
	a: ^Text_Area, b: ^textedit.Buffer, text: ^Text, width, scale: f32,
) -> []Text_Area_Line {
	t := text_styled(text, .Body)
	area_wrap(a, b, &t, max(1, width - 2 * CONTROL_INSET * scale))
	return a.lines[:]
}

// How tall the box is for `width` pixels of box: the text's lines, but no fewer than `min_lines` and no
// more than `max_lines`, past which the text scrolls inside the box.
@(require_results)
text_area_height :: proc(
	a: ^Text_Area, b: ^textedit.Buffer, text: ^Text, width, scale: f32, min_lines, max_lines: int,
) -> f32 {
	lines := text_area_lines(a, b, text, width, scale)
	t := text_styled(text, .Body)
	rows := clamp(len(lines), max(1, min_lines), max(1, min_lines, max_lines))
	return f32(rows) * t.line_height + 2 * area_pad(&t, scale)
}

// The row holding `offset`: the last line that starts at or before it, so the offset where a wrapped
// line ends is the start of the next line.
@(private = "file")
area_row :: proc(a: ^Text_Area, offset: int) -> int {
	low, high := 0, len(a.lines) - 1
	for low < high {
		mid := (low + high + 1) / 2
		if a.lines[mid].start <= offset {
			low = mid
		} else {
			high = mid - 1
		}
	}
	return low
}

// The offset in `row` nearest to `x` pixels from the text's left edge.
@(private = "file")
area_offset_in_row :: proc(a: ^Text_Area, b: ^textedit.Buffer, t: ^Text, row: int, x: f32) -> int {
	line := a.lines[row]
	row_line := area_row_line(t, textedit.to_string(b)[line.start:line.end])
	at := line.start + text_line_offset_at(row_line, x)
	// The end of a wrapped line is the start of the next one, so the caret stays before its last cluster.
	wrapped := row + 1 < len(a.lines) && a.lines[row + 1].start == line.end
	if at == line.end && line.end > line.start && wrapped {
		return line.start + text_line_previous(row_line, line.end - line.start)
	}
	return at
}

// How far `offset` is from the text's left edge on its row.
@(private = "file")
area_x_of :: proc(a: ^Text_Area, b: ^textedit.Buffer, t: ^Text, row, offset: int) -> f32 {
	line := a.lines[row]
	return text_line_x(area_row_line(t, textedit.to_string(b)[line.start:line.end]), offset - line.start)
}

@(private = "file")
area_max_scroll :: proc(a: ^Text_Area, frame: render.Rect, t: ^Text) -> f32 {
	return max(0, f32(len(a.lines)) * t.line_height - frame.height)
}

@(private = "file")
area_floor :: proc(b: ^textedit.Buffer, offset: int) -> int {
	return b.floor + grapheme_floor(textedit.to_string(b)[b.floor:], offset - b.floor)
}

@(private = "file")
area_ceil :: proc(b: ^textedit.Buffer, offset: int) -> int {
	s := textedit.to_string(b)[b.floor:]
	return b.floor + grapheme_ceil(s, offset - b.floor)
}

// A selection from the host can still be on rune boundaries. Paint and erase whole clusters.
@(private = "file")
area_selection :: proc(b: ^textedit.Buffer) -> (low, high: int) {
	from, to := textedit.selection(b)
	if from == to {return from, to}
	return area_floor(b, from), area_ceil(b, to)
}

@(private = "file")
area_move :: proc(b: ^textedit.Buffer, at: int, extend: bool) {
	if extend {
		b.anchor = b.anchor > b.caret ? area_ceil(b, b.anchor) : area_floor(b, b.anchor)
	}
	textedit.move(b, at, extend)
}

@(private = "file")
area_step :: proc(b: ^textedit.Buffer, offset: int, forward, word: bool) -> int {
	s := textedit.to_string(b)[b.floor:]
	at := offset - b.floor
	if forward {
		if word {return b.floor + grapheme_word_right(s, at, true)}
		return b.floor + grapheme_after(s, grapheme_floor(s, at))
	}
	if !word {return b.floor + grapheme_before(s, at)}
	// Ctrl+Left skips spaces, including hard breaks, before taking a run on the preceding line.
	at = area_ceil(b, offset) - b.floor
	for at > 0 {
		previous := grapheme_before(s, at)
		class := grapheme_word_class(s, previous)
		line := textedit.line_start(b, b.floor + previous) - b.floor
		at = line + grapheme_class_start(s[line:], at - line, class)
		if class != .Space {return b.floor + at}
	}
	return b.floor
}

// Left or Right: one grapheme (or word), collapsing an unextended selection in that direction.
text_area_horizontal :: proc(box: Text_Area_Box, forward, word, extend: bool) {
	b := box.buffer
	target: int
	if !extend && b.anchor != b.caret {
		low, high := area_selection(b)
		target = forward ? high : low
	} else {
		target = area_step(b, b.caret, forward, word)
	}
	area_move(b, target, extend)
	text_area_reveal(box)
}

// Backspace or Delete: erase whole graphemes, retaining textedit's undo grouping.
@(require_results)
text_area_erase :: proc(b: ^textedit.Buffer, forward, word: bool) -> bool {
	low, high := area_selection(b)
	run := textedit.Run.None
	if b.anchor == b.caret {
		run = .Deleting
		if forward {
			low = area_floor(b, low)
			high = area_step(b, b.caret, true, word)
		} else {
			low = area_step(b, b.caret, false, word)
			high = area_ceil(b, b.caret)
		}
	}
	return low == high || textedit.replace(b, low, high, "", run)
}

// The offset nearest to a point inside the box.
@(require_results)
text_area_offset_at :: proc(box: Text_Area_Box, x, y: f32) -> int {
	frame, t := area_laid_out(box)
	a := box.area
	row := clamp(int(math.floor((y - frame.y + a.scroll) / t.line_height)), 0, len(a.lines) - 1)
	return area_offset_in_row(a, box.buffer, &t, row, x - frame.x)
}

// The cell the caret occupies for `offset`, in the window: the cluster under it, or a space at the end of
// a line, one line tall.
@(require_results)
text_area_caret_rect :: proc(box: Text_Area_Box, offset: int) -> render.Rect {
	frame, t := area_laid_out(box)
	a := box.area
	s := textedit.to_string(box.buffer)
	at := textedit.clamp_offset(box.buffer, offset)
	row := area_row(a, at)
	line := a.lines[row]
	row_line := area_row_line(&t, s[line.start:line.end])
	x := text_line_x(row_line, at - line.start)
	width: f32
	if at < line.end && s[at] != '\r' {
		width = text_line_x(row_line, text_line_next(row_line, at - line.start)) - x
	} else {
		width = code_space(&t)
	}
	return {frame.x + x, frame.y + f32(row) * t.line_height - a.scroll, max(1, width), t.line_height}
}

// Scrolls the text so the caret is in the box, once for each place the caret and the box have been in;
// the scroll then stays wherever the wheel leaves it.
text_area_reveal :: proc(box: Text_Area_Box) {
	frame, t := area_laid_out(box)
	a, b := box.area, box.buffer
	at := textedit.clamp_offset(b, b.caret)
	if !(a.revealed && a.revealed_caret == at && a.revealed_revision == b.revision &&
		   a.revealed_height == frame.height && a.revealed_width == a.wrapped_width) {
		top := f32(area_row(a, at)) * t.line_height
		if top < a.scroll {
			a.scroll = top
		} else if top + t.line_height > a.scroll + frame.height {
			a.scroll = top + t.line_height - frame.height
		}
		a.revealed, a.revealed_caret, a.revealed_revision = true, at, b.revision
		a.revealed_height, a.revealed_width = frame.height, a.wrapped_width
	}
	a.scroll = clamp(a.scroll, 0, area_max_scroll(a, frame, &t))
}

// Scrolls by `delta` pixels down, as far as the text goes. False when nothing moved.
text_area_scroll :: proc(box: Text_Area_Box, delta: f32) -> bool {
	frame, t := area_laid_out(box)
	a := box.area
	was := a.scroll
	a.scroll = clamp(a.scroll + delta, 0, area_max_scroll(a, frame, &t))
	return a.scroll != was
}

// Scrolls by `lines` lines down, without moving the caret. False when nothing moved.
text_area_scroll_lines :: proc(box: Text_Area_Box, lines: int) -> bool {
	_, t := area_laid_out(box)
	return text_area_scroll(box, f32(lines) * t.line_height)
}

// Home or End: to the start or end of the caret's row, as the box wraps it, then as the shared rules go
// on (`textedit.home_target`, `textedit.end_target`).
text_area_row_edge :: proc(box: Text_Area_Box, end, extend: bool) {
	_, t := area_laid_out(box)
	a, b := box.area, box.buffer
	at := area_floor(b, b.caret)
	row := area_row(a, at)
	target: int
	if end {
		target = textedit.end_target(b, area_offset_in_row(a, b, &t, row, max(f32)))
	} else {
		target = textedit.home_target(b, a.lines[row].start)
		target = area_floor(b, target)
		if target == at {target = textedit.line_start(b, at)}
	}
	area_move(b, target, extend)
	text_area_reveal(box)
}

// Up, Down, Page Up and Page Down: moves the caret `lines` lines (or `pages` boxes of lines) away,
// keeping its column across shorter lines. Past the first or last line it goes to the text's start or end.
text_area_vertical :: proc(box: Text_Area_Box, lines, pages: int, extend: bool) {
	frame, t := area_laid_out(box)
	a, b := box.area, box.buffer
	at := textedit.clamp_offset(b, b.caret)
	row := area_row(a, at)
	x: f32
	if a.goal_set && a.goal_caret == b.caret && a.goal_revision == b.revision {
		x = a.goal_x
	} else {
		x = area_x_of(a, b, &t, row, at)
	}
	page := max(1, int(math.round(frame.height / t.line_height)) - 1)
	target_row := row + lines + pages * page
	target: int
	switch {
	case target_row < 0:
		target = b.floor
	case target_row >= len(a.lines):
		target = len(b.text)
	case:
		target = area_offset_in_row(a, b, &t, target_row, x)
	}
	area_move(b, target, extend)
	a.goal_x, a.goal_caret, a.goal_revision, a.goal_set = x, b.caret, b.revision, true
	text_area_reveal(box)
}

@(private = "file")
area_unit_at :: proc(b: ^textedit.Buffer, at: int, unit: textedit.Unit) -> (low, high: int) {
	if unit == .Line {return textedit.line_at(b, at)}
	start, end := textedit.line_start(b, at), textedit.line_end(b, at)
	from, to := grapheme_word_at(textedit.to_string(b)[start:end], at - start)
	return start + from, start + to
}

// A pointer press or drag at a point of the window moves the caret there, or extends the selection to
// it; a press starts a new selection unless `extend` is held. A press that is a second or third click
// of a run selects the word or the line there instead, and the drag after it grows by words or lines.
// False for a move with no press before it.
text_area_pointer :: proc(box: Text_Area_Box, x, y: f32, pressed, extend: bool, clicks := 1) -> bool {
	a, b := box.area, box.buffer
	if !pressed && !a.dragging {return false}
	at := text_area_offset_at(box, x, y)
	switch unit, by_unit := a.unit.?; {
	case pressed && clicks > 1 && !extend:
		chosen: textedit.Unit = clicks == 2 ? .Word : .Line
		from, to := area_unit_at(b, at, chosen)
		b.anchor, b.caret = from, to
		a.unit, a.unit_from, a.unit_to = chosen, from, to
	case !pressed && by_unit:
		from, to := area_unit_at(b, at, unit)
		if from < a.unit_from {
			b.anchor, b.caret = a.unit_to, from
		} else {
			b.anchor, b.caret = a.unit_from, max(to, a.unit_to)
		}
	case:
		area_move(b, at, pressed ? extend : true)
		a.unit = nil
	}
	if pressed {a.dragging = true}
	text_area_reveal(box)
	return true
}

// Ends a pointer drag in the box, returning whether one was under way.
text_area_release :: proc(a: ^Text_Area) -> bool {
	dragging := a.dragging
	a.dragging, a.unit = false, nil
	return dragging
}

// Draws the box: its field look, the selection, the text or the placeholder, and the caret.
text_area_draw :: proc(
	box: Text_Area_Box, list: ^render.Draw_List, theme: Theme, focused: bool, placeholder: string,
) -> render.Build_Status {
	text_area_reveal(box)
	frame, t := area_laid_out(box)
	a, b := box.area, box.buffer
	box_draw(list, box.rect, theme, focused, box.scale)
	scope, opened := clip_scope_open(list, box.rect, RADIUS_CONTROL * box.scale)
	if !opened {return .Ok}
	defer clip_scope_close(list, scope)
	s := textedit.to_string(b)
	lh := t.line_height
	first := max(0, int(math.floor(a.scroll / lh)))
	last := min(len(a.lines) - 1, int(math.ceil((a.scroll + frame.height) / lh)) - 1)
	low, high := area_selection(b)
	space := focused && low != high ? code_space(&t) : 0
	for row in first ..= last {
		if rect, selected := area_selection_rect(a, &t, s, frame, row, low, high, space); selected && focused {
			draw_rect(list, {rect = rect, color = theme.text_selection})
		}
	}
	head: render.Rect
	shown := false
	if focused {
		cell := text_area_caret_rect(box, b.caret)
		drawn: bool
		head, drawn = field_caret_pose(&a.caret, t.carets, {frame.x, frame.y - a.scroll}, cell, theme)
		shown = drawn && caret_shown(t.carets, a.caret.motion.active)
		if drawn {field_caret_body(&a.caret, list, theme)}
	}
	if len(s) == 0 {
		if result := draw_text(&t, list, placeholder, frame.x, frame.y + t.ascent, theme.muted, frame.width);
		   result != .Ok {
			return result
		}
	} else {
		for row in first ..= last {
			line := a.lines[row]
			baseline := frame.y + f32(row) * lh - a.scroll + t.ascent
			if result := area_row_draw(&t, list, s[line.start:line.end], frame.x, baseline, theme.text);
			   result != .Ok {
				return result
			}
		}
	}
	// Selected text takes the theme's selection text colour, as a terminal's does, when it sets one.
	if ink, recolour := theme.text_selection_text.?; recolour && focused && low != high {
		for row in first ..= last {
			rect, selected := area_selection_rect(a, &t, s, frame, row, low, high, space)
			if !selected {continue}
			line := a.lines[row]
			baseline := frame.y + f32(row) * lh - a.scroll + t.ascent
			again, scoped := clip_scope_open(list, rect)
			if !scoped {continue}
			draw_rect(list, {rect = rect, color = theme.text_selection})
			result := area_row_draw(&t, list, s[line.start:line.end], frame.x, baseline, ink)
			clip_scope_close(list, again)
			if result != .Ok {return result}
		}
	}
	if !shown {return .Ok}
	caret_scope, block := field_caret_head(list, &a.caret, theme, head)
	if !block {return .Ok}
	defer clip_scope_close(list, caret_scope)
	// The block covers the text under it, which draws again over it in the cursor text colour.
	if len(s) == 0 {
		return draw_text(&t, list, placeholder, frame.x, frame.y + t.ascent, theme.caret_text, frame.width)
	}
	for row in first ..= last {
		line := a.lines[row]
		top := frame.y + f32(row) * lh - a.scroll
		if top + lh <= head.y || top >= head.y + head.height {continue}
		baseline := top + t.ascent
		if result := area_row_draw(&t, list, s[line.start:line.end], frame.x, baseline, theme.caret_text);
		   result != .Ok {
			return result
		}
	}
	return .Ok
}

// The part of row `row` the selection covers, in the window; false when it covers none. `space` is the
// width a selected line break adds.
@(private = "file")
area_selection_rect :: proc(
	a: ^Text_Area, t: ^Text, s: string, frame: render.Rect, row, low, high: int, space: f32,
) -> (rect: render.Rect, selected: bool) {
	if low == high {return}
	line := a.lines[row]
	next := row + 1 < len(a.lines) ? a.lines[row + 1].start : line.end
	hard := next > line.end
	if !(high > line.start && low < (hard ? next : line.end)) {return}
	row_line := area_row_line(t, s[line.start:line.end])
	left := frame.x + text_line_x(row_line, clamp(low, line.start, line.end) - line.start)
	right := frame.x + text_line_x(row_line, clamp(high, line.start, line.end) - line.start)
	if hard && high >= next {right += space}
	right = min(right, frame.x + frame.width)
	return {left, frame.y + f32(row) * t.line_height - a.scroll, right - left, t.line_height}, true
}

// Wraps the selection in `before` and `after`, as a formatting button does; with nothing selected it
// wraps `placeholder`. The text between them ends up selected, so the next press or typing replaces it.
// One undo step. False when the buffer has no room, leaving it unchanged.
@(require_results)
text_area_wrap_selection :: proc(b: ^textedit.Buffer, before, after, placeholder: string) -> bool {
	from, to := textedit.selection(b)
	inner := to > from ? string(b.text[from:to]) : placeholder
	joined, err := strings.concatenate({before, inner, after}, context.temp_allocator)
	if err != nil || !textedit.replace(b, from, to, joined) {return false}
	b.anchor = from + len(before)
	b.caret = b.anchor + len(inner)
	return true
}

// Puts a fenced block, ```lang, `body` and the closing fence, at the caret on lines of its own, in place
// of the selection, and selects the body. One undo step. False when the buffer has no room.
@(require_results)
text_area_insert_block :: proc(b: ^textedit.Buffer, lang, body: string) -> bool {
	from, to := textedit.selection(b)
	lead := from > b.floor && b.text[from - 1] != '\n' ? b.newline : ""
	head, head_error := strings.concatenate({lead, "```", lang, b.newline}, context.temp_allocator)
	block, block_error := strings.concatenate({head, body, b.newline, "```", b.newline}, context.temp_allocator)
	if head_error != nil || block_error != nil || !textedit.replace(b, from, to, block) {return false}
	b.anchor = from + len(head)
	b.caret = b.anchor + len(body)
	return true
}
