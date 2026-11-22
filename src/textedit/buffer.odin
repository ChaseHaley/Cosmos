package textedit

import "core:mem"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Text as an editor holds it: its bytes as they are on disk, byte order mark and line endings included,
// a caret and selection, and undo history.
Buffer :: struct {
	text:          [dynamic]u8,
	// The selection runs from anchor to caret, byte offsets into text; equal when nothing is selected.
	caret, anchor: int,
	// No caret goes before the byte order mark.
	floor:         int,
	// What Enter inserts: the file's own line ending.
	newline:       string,
	undo, redo:    [dynamic]Edit,
	// Counts changes to the text, so what shows it knows to rebuild.
	revision:      u64,
}

// One change, which undo reverses. Both strings are owned.
Edit :: struct {
	at:                          int,
	removed, inserted:           string,
	caret_before, anchor_before: int,
	// Typing and deleting a run of characters join one edit, which undo reverses whole.
	run:                         Run,
}

Run :: enum u8 {
	None,
	Typing,
	Deleting,
}

// Edits the history keeps; the oldest go first.
@(private)
UNDO_LIMIT :: 1000

// A UTF-8 byte order mark, which no caret goes before.
@(private)
BOM :: "\xef\xbb\xbf"

@(require_results)
init :: proc(b: ^Buffer, text: string) -> bool {
	b^ = {}
	if _, err := append(&b.text, text); err != nil {return false}
	text_adopted(b)
	return true
}

destroy :: proc(b: ^Buffer) {
	delete(b.text)
	history_clear(b)
	delete(b.undo)
	delete(b.redo)
	b^ = {}
}

// Takes the file's text as it now is on disk, keeping the caret near where it was. The history
// described the old text, so it goes.
@(require_results)
reset :: proc(b: ^Buffer, text: string) -> bool {
	clear(&b.text)
	if _, err := append(&b.text, text); err != nil {return false}
	history_clear(b)
	text_adopted(b)
	b.caret = clamp_offset(b, b.caret)
	b.anchor = clamp_offset(b, b.anchor)
	return true
}

@(private)
text_adopted :: proc(b: ^Buffer) {
	text := string(b.text[:])
	b.floor = strings.has_prefix(text, BOM) ? len(BOM) : 0
	b.newline = "\n"
	line_end := strings.index_byte(text, '\n')
	if line_end > 0 && text[line_end - 1] == '\r' {b.newline = "\r\n"}
	b.revision += 1
}

@(private)
history_clear :: proc(b: ^Buffer) {
	for edit in b.undo {edit_free(edit)}
	for edit in b.redo {edit_free(edit)}
	clear(&b.undo)
	clear(&b.redo)
}

@(private)
edit_free :: proc(edit: Edit) {
	delete(edit.removed)
	delete(edit.inserted)
}

@(require_results)
to_string :: proc(b: ^Buffer) -> string {
	return string(b.text[:])
}

@(require_results)
selection :: proc(b: ^Buffer) -> (from, to: int) {
	return min(b.anchor, b.caret), max(b.anchor, b.caret)
}

@(require_results)
selected_text :: proc(b: ^Buffer) -> string {
	from, to := selection(b)
	return string(b.text[from:to])
}

// An offset moved onto the text and off the middle of a character or a CRLF pair.
@(require_results)
clamp_offset :: proc(b: ^Buffer, offset: int) -> int {
	at := clamp(offset, b.floor, len(b.text))
	for at > b.floor && at < len(b.text) && !utf8.rune_start(b.text[at]) {at -= 1}
	if at > b.floor && at < len(b.text) && b.text[at] == '\n' && b.text[at - 1] == '\r' {at -= 1}
	return at
}

// Moves the caret; without `extend` the selection collapses onto it.
move :: proc(b: ^Buffer, at: int, extend := false) {
	b.caret = clamp_offset(b, at)
	if !extend {b.anchor = b.caret}
}

select_all :: proc(b: ^Buffer) {
	b.anchor, b.caret = b.floor, len(b.text)
}

// The start of the character before `at`; a CRLF pair is one character.
@(require_results)
left :: proc(b: ^Buffer, at: int) -> int {
	if at <= b.floor {return b.floor}
	if at >= 2 && b.text[at - 1] == '\n' && b.text[at - 2] == '\r' {return at - 2}
	_, size := utf8.decode_last_rune(b.text[b.floor:at])
	return at - max(size, 1)
}

// The end of the character from `at`.
@(require_results)
right :: proc(b: ^Buffer, at: int) -> int {
	if at >= len(b.text) {return len(b.text)}
	if b.text[at] == '\r' && at + 1 < len(b.text) && b.text[at + 1] == '\n' {return at + 2}
	_, size := utf8.decode_rune(b.text[at:])
	return at + max(size, 1)
}

@(private)
word_rune :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r) || r == '_'
}

// Back over spaces, then over a word or a run of other marks, as Ctrl+Left goes.
@(require_results)
word_left :: proc(b: ^Buffer, at: int) -> int {
	at := at
	for at > b.floor {
		r, _ := utf8.decode_last_rune(b.text[b.floor:at])
		if !unicode.is_space(r) {break}
		at = left(b, at)
	}
	if at <= b.floor {return b.floor}
	r, _ := utf8.decode_last_rune(b.text[b.floor:at])
	word := word_rune(r)
	for at > b.floor {
		previous, _ := utf8.decode_last_rune(b.text[b.floor:at])
		if unicode.is_space(previous) || word_rune(previous) != word {break}
		at = left(b, at)
	}
	return at
}

// Over a word or a run of other marks, then the spaces after it, as Ctrl+Right goes.
@(require_results)
word_right :: proc(b: ^Buffer, at: int) -> int {
	at := at
	if at < len(b.text) {
		r, _ := utf8.decode_rune(b.text[at:])
		if !unicode.is_space(r) {
			word := word_rune(r)
			for at < len(b.text) {
				next, _ := utf8.decode_rune(b.text[at:])
				if unicode.is_space(next) || word_rune(next) != word {break}
				at = right(b, at)
			}
		}
	}
	for at < len(b.text) {
		next, _ := utf8.decode_rune(b.text[at:])
		if !unicode.is_space(next) || next == '\n' || next == '\r' {break}
		at = right(b, at)
	}
	return at
}

// The start of the line holding `at`.
@(require_results)
line_start :: proc(b: ^Buffer, at: int) -> int {
	start := strings.last_index_byte(string(b.text[:at]), '\n') + 1
	return max(start, b.floor)
}

// The end of the line holding `at`, before its line ending.
@(require_results)
line_end :: proc(b: ^Buffer, at: int) -> int {
	end := strings.index_byte(string(b.text[at:]), '\n')
	end = end < 0 ? len(b.text) : at + end
	if end > at && b.text[end - 1] == '\r' {end -= 1}
	return end
}

// What a double click selects and a drag after it grows by: the word under the pointer, or the whole line.
Unit :: enum u8 {
	Word,
	Line,
}

@(private)
Class :: enum u8 {
	None,
	Space,
	Word,
	Other,
}

@(private)
rune_class :: proc(r: rune) -> Class {
	switch {
	case unicode.is_space(r): return .Space
	case word_rune(r): return .Word
	}
	return .Other
}

// The word at `at`, as Ctrl+Left and Ctrl+Right take words: a run of word characters, or on spaces or
// other marks the run of those. A caret between two kinds takes the word it touches, so the end of a
// word selects the word, not the space after it. Never crosses a line break; an empty line selects nothing.
@(require_results)
word_at :: proc(b: ^Buffer, offset: int) -> (from, to: int) {
	at := clamp_offset(b, offset)
	start, end := line_start(b, at), line_end(b, at)
	before, after: Class
	if at > start {
		r, _ := utf8.decode_last_rune(b.text[start:at])
		before = rune_class(r)
	}
	if at < end {
		r, _ := utf8.decode_rune(b.text[at:end])
		after = rune_class(r)
	}
	class: Class
	switch {
	case after == .Word || before == .Word: class = .Word
	case after == .Other || before == .Other: class = .Other
	case after == .Space || before == .Space: class = .Space
	case: return at, at
	}
	from, to = at, at
	for from > start {
		r, size := utf8.decode_last_rune(b.text[start:from])
		if rune_class(r) != class {break}
		from -= size
	}
	for to < end {
		r, size := utf8.decode_rune(b.text[to:end])
		if rune_class(r) != class {break}
		to += size
	}
	return from, to
}

// The line holding `at` with its line ending, as a triple click selects it; the last line has none.
@(require_results)
line_at :: proc(b: ^Buffer, offset: int) -> (from, to: int) {
	at := clamp_offset(b, offset)
	from, to = line_start(b, at), line_end(b, at)
	if to < len(b.text) {to = right(b, to)}
	return from, to
}

@(require_results)
unit_at :: proc(b: ^Buffer, at: int, unit: Unit) -> (from, to: int) {
	if unit == .Word {return word_at(b, at)}
	return line_at(b, at)
}

// Selects the unit at `at`, or after the click that selected `from`..`to`, a drag to `at`: the selection
// keeps that first unit and grows by whole units toward the pointer, the caret on the side it moved to.
select_unit :: proc(b: ^Buffer, from, to: int, unit: Unit, at: int) {
	start, end := unit_at(b, at, unit)
	if start < from {
		b.anchor, b.caret = to, start
	} else {
		b.anchor, b.caret = from, max(end, to)
	}
}

// Where Home takes the caret. `row_start` is the start of the row the caret is on, which differs from the
// line's start on a soft-wrapped line: the first press goes there. Then it toggles between the line's
// first character that is not a space or tab and its start.
@(require_results)
home_target :: proc(b: ^Buffer, row_start: int) -> int {
	start := line_start(b, b.caret)
	if row_start != start && b.caret != row_start {return row_start}
	end := line_end(b, start)
	indent := start
	for indent < end && (b.text[indent] == ' ' || b.text[indent] == '\t') {indent += 1}
	return b.caret != indent && indent < end ? indent : start
}

// Where End takes the caret: `row_end` first, the last place the caret reaches on its soft-wrapped row,
// then the line's end.
@(require_results)
end_target :: proc(b: ^Buffer, row_end: int) -> int {
	end := line_end(b, b.caret)
	return row_end != end && b.caret != row_end ? row_end : end
}

// Replaces from..to with `text`, recorded for undo; the caret lands after the new text. A `run` joins
// the edit before it when it carries on where that one stopped.
@(require_results)
replace :: proc(b: ^Buffer, start, stop: int, text: string, run := Run.None) -> bool {
	from, to := clamp(start, b.floor, len(b.text)), clamp(stop, b.floor, len(b.text))
	if from == to && text == "" {return true}
	removed := string(b.text[from:to])
	if !join(b, from, to, removed, text, run) {
		edit := Edit {
			at            = from,
			caret_before  = b.caret,
			anchor_before = b.anchor,
			run           = run,
		}
		removed_error, inserted_error: mem.Allocator_Error
		edit.removed, removed_error = strings.clone(removed)
		edit.inserted, inserted_error = strings.clone(text)
		if removed_error != nil || inserted_error != nil {
			edit_free(edit)
			return false
		}
		if len(b.undo) >= UNDO_LIMIT {
			edit_free(b.undo[0])
			ordered_remove(&b.undo, 0)
		}
		if _, err := append(&b.undo, edit); err != nil {
			edit_free(edit)
			return false
		}
	}
	for edit in b.redo {edit_free(edit)}
	clear(&b.redo)
	if !splice(b, from, to, text) {return false}
	b.caret = from + len(text)
	b.anchor = b.caret
	return true
}

// Extends the last edit with this one when both belong to one run of typing or deleting.
@(private)
join :: proc(b: ^Buffer, from, to: int, removed, text: string, run: Run) -> bool {
	if run == .None || len(b.undo) == 0 || len(b.redo) > 0 {return false}
	last := &b.undo[len(b.undo) - 1]
	if last.run != run {return false}
	parts: [2]string
	switch run {
	case .None:
		return false
	case .Typing:
		// A space after a word starts the next undo step, so undo takes back a word at a time.
		if from != to || from != last.at + len(last.inserted) || last.inserted == "" {return false}
		if text == " " && !strings.has_suffix(last.inserted, " ") {return false}
		joined, err := strings.concatenate({last.inserted, text})
		if err != nil {return false}
		delete(last.inserted)
		last.inserted = joined
		return true
	case .Deleting:
		if text != "" || last.inserted != "" {return false}
		switch {
		case to == last.at:
			parts = {removed, last.removed}
		case from == last.at:
			parts = {last.removed, removed}
		case:
			return false
		}
	}
	joined, err := strings.concatenate(parts[:])
	if err != nil {return false}
	delete(last.removed)
	last.removed = joined
	last.at = min(last.at, from)
	return true
}

@(private, require_results)
splice :: proc(b: ^Buffer, from, to: int, text: string) -> bool {
	removed := to - from
	grow := len(text) - removed
	old := len(b.text)
	if grow > 0 {
		if err := resize(&b.text, old + grow); err != nil {return false}
		copy(b.text[to + grow:], b.text[to:old])
	} else if grow < 0 {
		copy(b.text[from + len(text):], b.text[to:old])
		resize(&b.text, old + grow)
	}
	copy(b.text[from:], text)
	b.revision += 1
	return true
}

// Inserts at the caret over the selection. Typing joins one undo step with the characters before it.
@(require_results)
insert :: proc(b: ^Buffer, text: string, typing := false) -> bool {
	from, to := selection(b)
	return replace(b, from, to, text, typing && from == to ? .Typing : .None)
}

// Deletes the selection, or the character (`word`: word) before or after the caret.
@(require_results)
erase :: proc(b: ^Buffer, forward, word: bool) -> bool {
	from, to := selection(b)
	if from == to {
		if forward {
			to = word ? word_right(b, b.caret) : right(b, b.caret)
		} else {
			from = word ? word_left(b, b.caret) : left(b, b.caret)
		}
		if from == to {return true}
		return replace(b, from, to, "", .Deleting)
	}
	return replace(b, from, to, "")
}

@(require_results)
undo :: proc(b: ^Buffer) -> bool {
	if len(b.undo) == 0 {return false}
	edit := pop(&b.undo)
	if !splice(b, edit.at, edit.at + len(edit.inserted), edit.removed) {
		append(&b.undo, edit)
		return false
	}
	if _, err := append(&b.redo, edit); err != nil {edit_free(edit)}
	b.caret, b.anchor = edit.caret_before, edit.anchor_before
	return true
}

@(require_results)
redo :: proc(b: ^Buffer) -> bool {
	if len(b.redo) == 0 {return false}
	edit := pop(&b.redo)
	if !splice(b, edit.at, edit.at + len(edit.removed), edit.inserted) {
		append(&b.redo, edit)
		return false
	}
	edit.run = .None
	if _, err := append(&b.undo, edit); err != nil {edit_free(edit)}
	b.caret = edit.at + len(edit.inserted)
	b.anchor = b.caret
	return true
}
