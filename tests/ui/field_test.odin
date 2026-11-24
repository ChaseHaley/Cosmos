package ui_test

import "cosmos:font"
import "cosmos:input"
import "cosmos:ui"
import "core:strings"
import "core:testing"

// `k` as a press.
@(private = "file")
key :: proc(k: input.Key_Event) -> input.Key_Event {
	e := k
	e.pressed = true
	return e
}

@(test)
field_selection_replaces_moves_and_deletes_by_word :: proc(t: ^testing.T) {
	f: ui.Text_Field
	defer delete(f.bytes)
	ui.field_set(&f, "alpha beta")
	testing.expect_value(t, ui.field_key(&f, key({key = .A, modifiers = {.Control}})), ui.Field_Change.Moved)
	testing.expect_value(t, ui.field_key(&f, key({key = .A, modifiers = {.Control}})), ui.Field_Change.None)
	testing.expect_value(t, ui.field_text(&f, "z"), ui.Field_Change.Edited)
	testing.expect_value(t, ui.field_string(&f), "z")
	ui.field_set(&f, "one two  three")
	ui.field_key(&f, key({key = .Arrow_Left, modifiers = {.Control}}))
	testing.expect_value(t, f.cursor, 9)
	ui.field_key(&f, key({key = .Arrow_Left, modifiers = {.Control, .Shift}}))
	testing.expect_value(t, ui.field_selected_text(&f), "two  ")
	ui.field_key(&f, key({key = .Arrow_Right}))
	testing.expect_value(t, f.cursor, 9)
	testing.expect_value(t, ui.field_selected_text(&f), "")
	ui.field_key(&f, key({key = .Backspace, modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&f), "one three")
	ui.field_key(&f, key({key = .Delete, modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&f), "one ")
	ui.field_key(&f, key({key = .Home, modifiers = {.Shift}}))
	testing.expect_value(t, ui.field_selected_text(&f), "one ")
	ui.field_key(&f, key({key = .Delete}))
	testing.expect_value(t, ui.field_string(&f), "")
	testing.expect_value(t, ui.field_key(&f, key({key = .Backspace})), ui.Field_Change.None)
	testing.expect_value(t, ui.field_text(&f, "\x1b\x7f"), ui.Field_Change.None)
	testing.expect_value(t, ui.field_text(&f, "\xff"), ui.Field_Change.None)
	// Punctuation separates words in URLs and paths.
	ui.field_set(&f, "https://google.com")
	ui.field_key(&f, key({key = .Arrow_Left, modifiers = {.Control, .Shift}}))
	testing.expect_value(t, ui.field_selected_text(&f), "com")
	ui.field_key(&f, key({key = .Arrow_Left, modifiers = {.Control, .Shift}}))
	testing.expect_value(t, ui.field_selected_text(&f), ".com")
	ui.field_key(&f, key({key = .Arrow_Left, modifiers = {.Control, .Shift}}))
	testing.expect_value(t, ui.field_selected_text(&f), "google.com")
}

@(test)
field_pointer_drag_selects_between_offsets :: proc(t: ^testing.T) {
	f: ui.Text_Field
	defer delete(f.bytes)
	ui.field_set(&f, "héllo")
	testing.expect_value(t, ui.field_pointer(&f, 1, true, false), ui.Field_Change.Moved)
	testing.expect_value(t, ui.field_pointer(&f, 6, false, false), ui.Field_Change.Moved)
	testing.expect_value(t, ui.field_selected_text(&f), "éllo")
	testing.expect(t, ui.field_release(&f))
	testing.expect(t, !ui.field_release(&f), "a released field has no drag left to end")
	testing.expect_value(t, ui.field_pointer(&f, 0, false, false), ui.Field_Change.None)
	ui.field_pointer(&f, 0, true, true)
	testing.expect_value(t, ui.field_selected_text(&f), "h")
}

@(test)
a_field_atom_is_one_character_for_the_caret_the_selection_and_deletion :: proc(t: ^testing.T) {
	f: ui.Text_Field
	defer delete(f.bytes)
	ui.field_set(&f, `ab @"No vendor" cd`)
	f.atoms = []ui.Field_Atom{{3, 15}}
	ui.field_pointer(&f, 1, true, false, 2)
	ui.field_pointer(&f, 15, false, false)
	testing.expect_value(t, ui.field_selected_text(&f), `ab @"No vendor"`)
	ui.field_release(&f)
	f.cursor, f.anchor = 15, 15
	ui.field_key(&f, key({key = .Arrow_Left}))
	testing.expect_value(t, f.cursor, 3)
	ui.field_key(&f, key({key = .Arrow_Right}))
	testing.expect_value(t, f.cursor, 15)
	ui.field_key(&f, key({key = .Arrow_Left, modifiers = {.Shift}}))
	testing.expect_value(t, ui.field_selected_text(&f), `@"No vendor"`)
	ui.field_key(&f, key({key = .Arrow_Left, modifiers = {.Control}}))
	testing.expect_value(t, f.cursor, 3)
	f.cursor, f.anchor = 15, 15
	testing.expect_value(t, ui.field_key(&f, key({key = .Backspace})), ui.Field_Change.Edited)
	testing.expect_value(t, ui.field_string(&f), "ab  cd")
	f.atoms = nil
}

FIELD_URL :: "https://github.com/odin-lang/Odin/issues?q=webview"

// The byte offset `inside` characters into the first `part` of FIELD_URL.
@(private = "file")
url_at :: proc(part: string, inside := 1) -> int {
	return strings.index(FIELD_URL, part) + inside
}

@(test)
field_double_click_selects_the_word_between_url_punctuation :: proc(t: ^testing.T) {
	f: ui.Text_Field
	defer delete(f.bytes)
	ui.field_set(&f, FIELD_URL)
	words := [?]struct {
		part, word: string,
	}{{"github", "github"}, {"odin-lang", "odin"}, {"lang/", "lang"}, {"Odin/", "Odin"}, {"webview", "webview"}}
	for w in words {
		ui.field_pointer(&f, url_at(w.part), true, false, 2)
		testing.expect_value(t, ui.field_selected_text(&f), w.word)
		ui.field_release(&f)
	}
	// Punctuation between two marks selects as one run, as Ctrl+Left and Ctrl+Right step over it.
	ui.field_pointer(&f, url_at("://"), true, false, 2)
	testing.expect_value(t, ui.field_selected_text(&f), "://")
	ui.field_release(&f)
	// A caret at a word's end takes that word, not the mark after it.
	ui.field_pointer(&f, url_at("github", 6), true, false, 2)
	testing.expect_value(t, ui.field_selected_text(&f), "github")
	ui.field_release(&f)
	ui.field_pointer(&f, 0, true, false, 2)
	testing.expect_value(t, ui.field_selected_text(&f), "https")
	ui.field_release(&f)
	ui.field_pointer(&f, len(FIELD_URL), true, false, 2)
	testing.expect_value(t, ui.field_selected_text(&f), "webview")
}

@(test)
field_double_click_on_an_empty_field_selects_nothing :: proc(t: ^testing.T) {
	f: ui.Text_Field
	defer delete(f.bytes)
	testing.expect_value(t, ui.field_pointer(&f, 0, true, false, 2), ui.Field_Change.None)
	testing.expect_value(t, ui.field_pointer(&f, 0, true, false, 3), ui.Field_Change.None)
	testing.expect_value(t, ui.field_selected_text(&f), "")
}

@(test)
field_triple_click_selects_the_whole_field_and_a_drag_keeps_it :: proc(t: ^testing.T) {
	f: ui.Text_Field
	defer delete(f.bytes)
	ui.field_set(&f, FIELD_URL)
	testing.expect_value(t, ui.field_pointer(&f, url_at("lang"), true, false, 3), ui.Field_Change.Moved)
	testing.expect_value(t, ui.field_selected_text(&f), FIELD_URL)
	ui.field_pointer(&f, url_at("github"), false, true)
	testing.expect_value(t, ui.field_selected_text(&f), FIELD_URL)
	testing.expect(t, ui.field_release(&f))
}

@(test)
field_drag_after_a_double_click_grows_by_whole_words :: proc(t: ^testing.T) {
	f: ui.Text_Field
	defer delete(f.bytes)
	ui.field_set(&f, FIELD_URL)
	ui.field_pointer(&f, url_at("github"), true, false, 2)
	testing.expect_value(t, ui.field_selected_text(&f), "github")
	// Right: the word under the pointer joins whole, however far into it the pointer is.
	testing.expect_value(t, ui.field_pointer(&f, url_at("Odin"), false, true), ui.Field_Change.Moved)
	testing.expect_value(t, ui.field_selected_text(&f), "github.com/odin-lang/Odin")
	ui.field_pointer(&f, url_at("lang"), false, true)
	testing.expect_value(t, ui.field_selected_text(&f), "github.com/odin-lang")
	// Back inside the first word shrinks to it, and the opposite side grows the same way.
	ui.field_pointer(&f, url_at("github", 3), false, true)
	testing.expect_value(t, ui.field_selected_text(&f), "github")
	ui.field_pointer(&f, url_at("https", 2), false, true)
	testing.expect_value(t, ui.field_selected_text(&f), "https://github")
	testing.expect_value(t, f.cursor, 0)
	testing.expect_value(t, f.anchor, url_at("github", 6))
	testing.expect(t, ui.field_release(&f))
	// Released, the next move does nothing, and a plain press drags by characters again.
	testing.expect_value(t, ui.field_pointer(&f, 5, false, true), ui.Field_Change.None)
	ui.field_pointer(&f, url_at("Odin", 0), true, false)
	ui.field_pointer(&f, url_at("Odin", 3), false, true)
	testing.expect_value(t, ui.field_selected_text(&f), "Odi")
}

@(test)
field_shift_click_extends_instead_of_selecting_a_word :: proc(t: ^testing.T) {
	f: ui.Text_Field
	defer delete(f.bytes)
	ui.field_set(&f, FIELD_URL)
	ui.field_pointer(&f, 0, true, false)
	ui.field_release(&f)
	ui.field_pointer(&f, url_at("github", 3), true, true, 2)
	testing.expect_value(t, ui.field_selected_text(&f), "https://git")
}

// `start` must be the earliest caret stop, as the caret reaches them from the line's start, that fits
// its text up to the caret in `available`: its own span fits and the stop before it does not.
@(private = "file")
expect_view_start :: proc(t: ^testing.T, f: ^ui.Text_Field, text: ^ui.Text, available: f32, start: int) {
	value := ui.field_string(f)
	previous, stop := -1, 0
	for stop < start {
		previous, stop = stop, ui.rune_right(f, stop)
	}
	testing.expectf(t, stop == start, "start %d is not a caret stop", start)
	if start < f.cursor {
		fits := ui.text_width(text, value[start:f.cursor]) <= available
		testing.expectf(t, fits, "start %d overflows", start)
	}
	if previous >= 0 {
		late := ui.text_width(text, value[previous:f.cursor]) <= available
		testing.expectf(t, !late, "start %d is late: the stop at %d fits too", start, previous)
	}
}

@(test)
field_view_starts_at_the_earliest_caret_stop_that_fits :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, nil, 16)) {return}
	f: ui.Text_Field
	defer delete(f.bytes)

	// An atom is one stop: the view starts before it or after it, never inside.
	ui.field_set(&f, `ab @"No vendor" cd`)
	f.atoms = []ui.Field_Atom{{3, 15}}
	tail := ui.text_width(&text, `@"No vendor" cd`)
	widths := [?]f32{tail + 0.25, tail - 0.25, ui.text_width(&text, " cd") + 0.25, 0}
	for available in widths {
		expect_view_start(t, &f, &text, available, ui.field_view_start(&f, &text, available))
	}
	testing.expect_value(t, ui.field_view_start(&f, &text, tail + 0.25), 3)
	testing.expect_value(t, ui.field_view_start(&f, &text, tail - 0.25), 15)
	f.cursor, f.anchor = 15, 15
	atom := ui.text_width(&text, `@"No vendor"`)
	testing.expect_value(t, ui.field_view_start(&f, &text, atom - 0.25), 15)
	f.atoms = nil

	// A long line with the caret at its end shows only the text that fits before the caret.
	ui.field_set(&f, strings.repeat("lorem ipsum ", 200, context.temp_allocator))
	start := ui.field_view_start(&f, &text, 300)
	testing.expect(t, start > 0)
	expect_view_start(t, &f, &text, 300, start)
	f.cursor, f.anchor = 600, 600
	expect_view_start(t, &f, &text, 300, ui.field_view_start(&f, &text, 300))

	// Too narrow for even the character before the caret, the view starts at the caret.
	ui.field_set(&f, "héllo")
	testing.expect_value(t, ui.field_view_start(&f, &text, 1), len("héllo"))
	f.cursor, f.anchor = 3, 3
	testing.expect_value(t, ui.field_view_start(&f, &text, 1), 3)
	testing.expect_value(t, ui.field_view_start(&f, &text, 100), 0)
}
