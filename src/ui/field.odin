package ui

import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import "base:runtime"
import "core:unicode"
import "core:unicode/utf8"

// One line of editable text. The selection runs between anchor and cursor; they are equal when
// nothing is selected. Both are byte offsets on grapheme boundaries. `dragging` holds from a pointer press
// in the field until its owner calls field_release; `unit` is what that press selected, so a drag after
// a double click grows the selection by whole words from `word_from` to `word_to`. `caret` is how its
// caret last moved on screen. `clicks` is the field's run of pointer presses, which its owner counts.
Text_Field :: struct {
	bytes:              [dynamic]u8,
	cursor, anchor:     int,
	dragging:           bool,
	unit:               Field_Unit,
	word_from, word_to: int,
	caret:              Field_Caret,
	clicks:             Click_Mark,
	// Spans of bytes the caret steps over and Backspace and Delete remove whole. The owner keeps them
	// in order and apart and sets them again after every edit; the field never owns them.
	atoms:              []Field_Atom,
}

Field_Atom :: struct {
	start, end: int,
}

// What a pointer press in a field selected, and so how its drag moves the selection.
Field_Unit :: enum u8 {
	Caret,
	Word,
	Field,
}

// Where and when the last press of a run of clicks landed, and how many the run has.
Click_Mark :: struct {
	x:       f32,
	time_ns: i64,
	count:   int,
}

Field_Change :: enum {
	None,
	Moved,
	Edited,
}

field_string :: proc(f: ^Text_Field) -> string {
	return string(f.bytes[:])
}

field_selection :: proc(f: ^Text_Field) -> (start, end: int) {
	return min(f.anchor, f.cursor), max(f.anchor, f.cursor)
}

field_selected_text :: proc(f: ^Text_Field) -> string {
	start, end := field_selection(f)
	return string(f.bytes[start:end])
}

// Replaces the whole text. Without room for `value` the field keeps its text and reports the error.
field_set :: proc(f: ^Text_Field, value: string) -> runtime.Allocator_Error {
	if err := reserve(&f.bytes, len(value)); err != nil {return err}
	clear(&f.bytes)
	append(&f.bytes, ..transmute([]u8)value)
	f.cursor, f.anchor = len(f.bytes), len(f.bytes)
	field_release(f)
	return nil
}

field_select_all :: proc(f: ^Text_Field) {
	f.anchor, f.cursor = 0, len(f.bytes)
}

@(private)
field_delete_range :: proc(f: ^Text_Field, start, end: int) {
	copy(f.bytes[start:], f.bytes[end:])
	resize(&f.bytes, len(f.bytes) - (end - start))
	f.cursor, f.anchor = start, start
}

// Replaces the selection with the printable runes of `text`. Without room for all of them the field
// is left unchanged, so an edit is never applied in part.
field_text :: proc(f: ^Text_Field, text: string) -> Field_Change {
	if !utf8.valid_string(text) {return .None}
	start, end := field_selection(f)
	added := 0
	for r in text {
		if r >= ' ' && r != 0x7f {added += utf8.rune_size(r)}
	}
	if reserve(&f.bytes, len(f.bytes) - (end - start) + added) != nil {return .None}
	change := Field_Change.None
	if start != end {
		field_delete_range(f, start, end)
		change = .Edited
	}
	for r in text {
		if r < ' ' || r == 0x7f {continue}
		encoded, n := utf8.encode_rune(r)
		before := len(f.bytes)
		resize(&f.bytes, before + n)
		copy(f.bytes[f.cursor + n:], f.bytes[f.cursor:before])
		copy(f.bytes[f.cursor:], encoded[:n])
		f.cursor += n
		change = .Edited
	}
	if change == .Edited {f.cursor = grapheme_ceil(field_string(f), f.cursor)}
	f.anchor = f.cursor
	return change
}

// The edge of the atom a motion landed in the middle of, in the direction it was going.
@(private)
atom_edge :: proc(f: ^Text_Field, at: int, forward: bool) -> int {
	for atom in f.atoms {
		if at > atom.start && at < atom.end {return forward ? atom.end : atom.start}
	}
	return at
}

// Start the forward iterator at a known break, not an arbitrary lookback. The ASCII shortcut
// cannot cut an Extend, Prepend, Hangul, Indic, emoji or RI sequence, and excludes CRLF.
@(private)
grapheme_restart :: proc(s: string, offset: int) -> int {
	at := min(offset, len(s) - 1)
	for at > 0 {
		before, after := s[at - 1], s[at]
		if before == '\n' ||
		   (before < 0x80 && after < 0x80 && !(before == '\r' && after == '\n')) {
			return at
		}
		at -= 1
	}
	return 0
}

// The boundary at `at`, or the start of the cluster containing it.
@(private)
grapheme_floor :: proc(s: string, offset: int) -> int {
	at := clamp(offset, 0, len(s))
	if at == 0 || at == len(s) {return at}
	start := grapheme_restart(s, at)
	if start == at {return at}
	it := utf8.decode_grapheme_iterator_make(s[start:])
	for cluster, g in utf8.decode_grapheme_iterate(&it) {
		if start + g.byte_index + len(cluster) > at {return start + g.byte_index}
	}
	return len(s)
}

// The boundary strictly to the left of `at`, even when `at` is inside a cluster.
@(private)
grapheme_before :: proc(s: string, at: int) -> int {
	return grapheme_floor(s, at - 1)
}

@(private)
grapheme_ceil :: proc(s: string, offset: int) -> int {
	at := clamp(offset, 0, len(s))
	start := grapheme_floor(s, at)
	return start < at ? grapheme_after(s, start) : start
}

// The end of the cluster whose confirmed start is `at`.
@(private)
grapheme_after :: proc(s: string, at: int) -> int {
	if at + 1 >= len(s) {return len(s)}
	if s[at] < 0x80 && s[at + 1] < 0x80 {
		return at + (s[at] == '\r' && s[at + 1] == '\n' ? 2 : 1)
	}
	it := utf8.decode_grapheme_iterator_make(s[at:])
	cluster, _, _ := utf8.decode_grapheme_iterate(&it)
	return at + len(cluster)
}

// The caret stop before `at`: the start of the grapheme cluster before it, or of the atom holding that.
@(private)
caret_stop_left :: proc(f: ^Text_Field, at: int) -> int {
	if at <= 0 {return 0}
	return atom_edge(f, grapheme_before(field_string(f), at), false)
}

// The caret stop after `at`: the end of the grapheme cluster after it, or of the atom holding that.
caret_stop_right :: proc(f: ^Text_Field, at: int) -> int {
	if at >= len(f.bytes) {return len(f.bytes)}
	s := field_string(f)
	return atom_edge(f, grapheme_after(s, grapheme_floor(s, at)), true)
}

// Listed in the order preferred when the pointer lands between two classes.
@(private)
Grapheme_Word_Class :: enum u8 {
	None,
	Space,
	Other,
	Word,
}

@(private)
grapheme_word_class :: proc(s: string, at: int) -> Grapheme_Word_Class {
	if at >= len(s) {return .None}
	r, _ := utf8.decode_rune(s[at:])
	switch {
	case unicode.is_space(r): return .Space
	case unicode.is_letter(r) || unicode.is_digit(r) || r == '_': return .Word
	}
	return .Other
}

// Walk a run backward in blocks rather than resegmenting the same prefix for each cluster.
@(private)
grapheme_class_start :: proc(s: string, at: int, class: Grapheme_Word_Class) -> int {
	at := at
	for at > 0 {
		from := grapheme_restart(s, max(0, at - CLIP_BYTES))
		start := from
		it := utf8.decode_grapheme_iterator_make(s[from:at])
		for cluster, g in utf8.decode_grapheme_iterate(&it) {
			if grapheme_word_class(cluster, 0) != class {start = from + g.byte_index + len(cluster)}
		}
		if start > from {return start}
		at = from
	}
	return 0
}

// At a run boundary prefer a word, then punctuation, then spaces.
@(private)
grapheme_word_at :: proc(s: string, offset: int) -> (from, to: int) {
	at := grapheme_floor(s, offset)
	before := at > 0 ? grapheme_word_class(s, grapheme_before(s, at)) : Grapheme_Word_Class.None
	after := grapheme_word_class(s, at)
	class := u8(before) > u8(after) ? before : after
	from, to = at, at
	if before == class {from = grapheme_class_start(s, at, class)}
	it := utf8.decode_grapheme_iterator_make(s[at:])
	for cluster, _ in utf8.decode_grapheme_iterate(&it) {
		if grapheme_word_class(cluster, 0) != class {break}
		to += len(cluster)
	}
	return
}

@(private)
field_word_at :: proc(f: ^Text_Field, at: int) -> (from, to: int) {
	from, to = grapheme_word_at(field_string(f), at)
	return atom_edge(f, from, false), atom_edge(f, to, true)
}

// Back over spaces, then over a word or a run of punctuation.
@(private)
word_left :: proc(f: ^Text_Field, at: int) -> int {
	s := field_string(f)
	i := at
	for i > 0 {
		previous := grapheme_before(s, i)
		class := grapheme_word_class(s, previous)
		if len(f.atoms) == 0 {
			i = grapheme_class_start(s, i, class)
			if class != .Space {return i}
			continue
		}
		if class != .Space {
			for i > 0 && grapheme_word_class(s, grapheme_before(s, i)) == class {
				i = caret_stop_left(f, i)
			}
			return i
		}
		i = atom_edge(f, previous, false)
	}
	return i
}

// Forward over a word or a run of punctuation, then the spaces after it.
@(private)
grapheme_word_right :: proc(s: string, offset: int, same_line: bool) -> int {
	at := grapheme_floor(s, offset)
	class := grapheme_word_class(s, at)
	it := utf8.decode_grapheme_iterator_make(s[at:])
	for cluster, _ in utf8.decode_grapheme_iterate(&it) {
		next := grapheme_word_class(cluster, 0)
		if next == .Space {
			if same_line && (cluster[0] == '\r' || cluster[0] == '\n') {break}
			class = .Space
		} else if next != class {
			break
		}
		at += len(cluster)
	}
	return at
}

@(private)
word_right :: proc(f: ^Text_Field, at: int) -> int {
	s := field_string(f)
	if len(f.atoms) == 0 {return grapheme_word_right(s, at, false)}
	i := grapheme_floor(s, at)
	class := grapheme_word_class(s, i)
	for i < len(s) {
		next := grapheme_word_class(s, i)
		if next == .Space {
			class = .Space
		} else if next != class {
			break
		}
		i = atom_edge(f, grapheme_after(s, i), true)
	}
	return i
}

field_move :: proc(f: ^Text_Field, to: int, extend: bool) -> Field_Change {
	if extend {
		if to == f.cursor {return .None}
		f.cursor = to
		return .Moved
	}
	if to == f.cursor && f.anchor == f.cursor {return .None}
	f.cursor, f.anchor = to, to
	return .Moved
}

// Handles editing and caret keys. Clipboard chords belong to the caller, which owns the clipboard.
field_key :: proc(f: ^Text_Field, e: input.Key_Event) -> Field_Change {
	if !e.pressed {return .None}
	control := .Control in e.modifiers
	shift := .Shift in e.modifiers
	start, end := field_selection(f)
	#partial switch e.key {
	case .A:
		if control && .Alt not_in e.modifiers {
			if start == 0 && end == len(f.bytes) {return .None}
			field_select_all(f)
			return .Moved
		}
	case .Home:
		return field_move(f, 0, shift)
	case .End:
		return field_move(f, len(f.bytes), shift)
	case .Arrow_Left:
		if !shift && start != end {return field_move(f, start, false)}
		return field_move(f, control ? word_left(f, f.cursor) : caret_stop_left(f, f.cursor), shift)
	case .Arrow_Right:
		if !shift && start != end {return field_move(f, end, false)}
		return field_move(f, control ? word_right(f, f.cursor) : caret_stop_right(f, f.cursor), shift)
	case .Backspace, .Delete:
		if start == end {
			if e.key == .Backspace {
				start = control ? word_left(f, f.cursor) : caret_stop_left(f, f.cursor)
			} else {
				end = control ? word_right(f, f.cursor) : caret_stop_right(f, f.cursor)
			}
		}
		if start == end {return .None}
		field_delete_range(f, start, end)
		f.cursor = grapheme_floor(field_string(f), f.cursor)
		f.anchor = f.cursor
		return .Edited
	}
	if !control || .Alt in e.modifiers {return field_text(f, e.text)}
	return .None
}

// The text before a field's caret, laid out a window of CLIP_BYTES at a time back from the caret: the
// window is value[start:end], laid out in `line`, and `behind` is how wide the text from `end` to the
// caret is.
@(private = "file")
View_Window :: struct {
	text:       ^Text,
	value:      string,
	start, end: int,
	line:       Text_Line,
	behind:     f32,
}

// Moves the window to the text before it.
@(private = "file")
view_window_back :: proc(w: ^View_Window) {
	w.behind += text_line_x(w.line, w.end - w.start)
	w.end, w.start = w.start, max(0, w.start - CLIP_BYTES)
	w.start = grapheme_floor(w.value, w.start)
	w.line = text_line(w.text, w.value[w.start:w.end])
}

// The first byte shown when the caret must stay inside `available` pixels: the earliest caret stop whose
// text up to the caret fits. It walks left from the caret one stop at a time through windows of the text
// before it, so a long line costs only the text the view reaches into.
field_view_start :: proc(f: ^Text_Field, text: ^Text, available: f32) -> int {
	value := field_string(f)
	start := grapheme_floor(value, f.cursor)
	w := View_Window{text = text, value = value, start = start, end = start}
	for start > 0 {
		if start == w.start {view_window_back(&w)}
		previous := atom_edge(f, w.start + text_line_previous(w.line, start - w.start), false)
		for previous < w.start {view_window_back(&w)}
		width := w.behind + text_line_x(w.line, w.end - w.start) - text_line_x(w.line, previous - w.start)
		if width > available {break}
		start = previous
	}
	return start
}

// The caret stop nearest to `x` for text drawn from `origin` starting at byte `start`.
field_offset_at :: proc(f: ^Text_Field, text: ^Text, start: int, origin, x: f32) -> int {
	line := text_line(text, field_string(f)[start:], x - origin)
	return start + text_line_offset_at(line, x - origin)
}

// Pointer press or drag at offset `at`; a press starts a new selection unless `extend` is held. A press
// that is the second click of a run selects the word there and a third the whole field; the drag after
// a double click grows the selection by whole words toward the pointer, and after a triple click keeps
// the whole field. `clicks` is the press's count in its run, which the caller keeps; a drag needs none.
field_pointer :: proc(f: ^Text_Field, at: int, pressed, extend: bool, clicks := 1) -> Field_Change {
	before_anchor, before_cursor := f.anchor, f.cursor
	switch {
	case pressed && clicks > 1 && !extend:
		f.dragging = true
		if clicks == 2 {
			f.unit = .Word
			f.word_from, f.word_to = field_word_at(f, at)
			f.anchor, f.cursor = f.word_from, f.word_to
		} else {
			f.unit = .Field
			field_select_all(f)
		}
	case pressed:
		f.dragging, f.unit = true, .Caret
		return field_move(f, at, extend)
	case !f.dragging:
		return .None
	case f.unit == .Word:
		from, to := field_word_at(f, at)
		if from < f.word_from {
			f.anchor, f.cursor = f.word_to, from
		} else {
			f.anchor, f.cursor = f.word_from, max(to, f.word_to)
		}
	case f.unit == .Field:
	case:
		return field_move(f, at, true)
	}
	return f.anchor != before_anchor || f.cursor != before_cursor ? .Moved : .None
}

// Ends a pointer drag in the field, returning whether one was under way.
field_release :: proc(f: ^Text_Field) -> bool {
	dragging := f.dragging
	f.dragging, f.unit = false, .Caret
	return dragging
}

// The cell the caret occupies at `at`: the cluster under it, or a space past the end, one line tall. `line`
// is the text drawn from byte `start`.
@(private)
field_caret_cell :: proc(
	f: ^Text_Field, text: ^Text, line: Text_Line, start: int, at, baseline, right: f32,
) -> render.Rect {
	width := text_width(text, " ")
	if f.cursor < len(f.bytes) {
		width = text_line_x(line, caret_stop_right(f, f.cursor) - start) - text_line_x(line, f.cursor - start)
	}
	return {at, baseline - text.ascent, max(1, min(width, right - at)), text.line_height}
}

field_draw :: proc(
	f: ^Text_Field,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	x, baseline, available: f32,
	focused: bool,
	placeholder: string,
	color: render.Color,
) -> render.Build_Status {
	value := field_string(f)
	start := field_view_start(f, text, available)
	// The caret and the selection stand where draw_text below sets the text, as far as the field shows.
	line: Text_Line
	if focused {line = text_line(text, value[start:], available)}
	selection: render.Rect
	if focused && value != "" {
		low, high := field_selection(f)
		if low != high {
			left := x + text_line_x(line, max(start, low) - start)
			right := x + text_line_x(line, max(start, high) - start)
			left, right = min(left, x + available), min(right, x + available)
			selection = {left, baseline - text.ascent, right - left, text.line_height}
			draw_rect(list, {rect = selection, color = theme.text_selection})
		}
	}
	head: render.Rect
	shown := false
	if focused {
		at := x + min(available, text_line_x(line, f.cursor - start))
		cell := field_caret_cell(f, text, line, start, at, baseline, x + available)
		drawn: bool
		head, drawn = field_caret_pose(&f.caret, text.carets, {x, baseline}, cell, theme)
		shown = drawn && caret_shown(text.carets, f.caret.motion.active)
		if drawn {field_caret_body(&f.caret, list, theme)}
	}
	if value == "" {
		if result := draw_text(text, list, placeholder, x, baseline, theme.muted, available);
		   result != .Ok {
			return result
		}
	} else if result := draw_text(text, list, value[start:], x, baseline, color, available);
	   result != .Ok {
		return result
	}
	// Selected text takes the theme's selection text colour, as a terminal's does, when it sets one.
	if ink, recolour := theme.text_selection_text.?; recolour && selection.width > 0 {
		scope, opened := clip_scope_open(list, selection)
		if opened {
			draw_rect(list, {rect = selection, color = theme.text_selection})
			result := draw_text(text, list, value[start:], x, baseline, ink, available)
			clip_scope_close(list, scope)
			if result != .Ok {return result}
		}
	}
	if !shown {return .Ok}
	scope, block := field_caret_head(list, &f.caret, theme, head)
	if !block {return .Ok}
	defer clip_scope_close(list, scope)
	// The block covers what is under it, which draws again over it in the cursor text colour.
	under := value == "" ? placeholder : value[start:]
	return draw_text(text, list, under, x, baseline, theme.caret_text, available)
}

// Adds the field to the window's semantic tree under `parent` as a Text_Field named `name`, the label the
// app shows beside it or, without one, its hint. Its value is the field's text, empty when the field is
// blank and the hint shows. `rect` is the box the field draws in. `id` is the field's; when the app
// registers the field with Focus it passes platform.Access_Id of the field's Focus_Id.
field_access :: proc(
	f: ^Text_Field,
	t: ^Access_Tree,
	parent, id: platform.Access_Id,
	name: string,
	rect: render.Rect,
) {
	access_add(t, {id = id, parent = parent, role = .Text_Field, name = name, value = field_string(f),
		bounds = access_bounds(rect), states = {.Focusable}})
}
