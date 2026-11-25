package ui_test

import "cosmos:font"
import "cosmos:glyphs"
import "cosmos:render"
import "cosmos:test_fonts"
import "cosmos:ui"
import "core:mem"
import "core:testing"
import "core:time"

// Selawik, the bundled interface font, kerns nothing: its GPOS holds only mark positioning. Segoe UI,
// which every Windows install has, kerns "To" by -200/2048 em, so the kerning tests use it at a size where
// that is a few whole pixels.
@(private = "file")
KERNED_FAMILY :: "Segoe UI"

@(private = "file")
Kerned_Fixture :: struct {
	fonts:  ^font.System,
	device: ^render.Device,
	cache:  glyphs.Cache,
	text:   ui.Text,
	list:   render.Draw_List,
}

@(private = "file")
kerned_start :: proc(t: ^testing.T, f: ^Kerned_Fixture) -> bool {
	err: font.Error
	f.fonts, err = font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return false}
	device_error: render.Error
	f.device, device_error = render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {
		font.system_destroy(f.fonts)
		return false
	}
	glyphs.init(&f.cache, f.fonts, f.device)
	f.list = render.draw_list_init()
	return testing.expect(t, ui.text_init(&f.text, f.fonts, &f.cache, 32, KERNED_FAMILY))
}

@(private = "file")
kerned_stop :: proc(f: ^Kerned_Fixture) {
	render.draw_list_destroy(&f.list)
	glyphs.destroy(&f.cache)
	render.device_destroy(f.device)
	font.system_destroy(f.fonts)
}

// Draws `s` from `x` and returns where its last glyph landed.
@(private = "file")
last_glyph :: proc(t: ^testing.T, f: ^Kerned_Fixture, s: string, x: f32) -> render.Rect {
	render.draw_list_reset(&f.list)
	_ = render.push_layer(&f.list, {0, 0, 800, 100})
	testing.expect_value(t, ui.draw_text(&f.text, &f.list, s, x, 50, {1, 1, 1, 1}), render.Build_Status.Ok)
	if !testing.expect(t, len(f.list.glyphs) > 0, "nothing was drawn") {return {}}
	return f.list.glyphs[len(f.list.glyphs) - 1].rect
}

@(test)
a_kerned_pair_measures_and_draws_closer_than_its_glyphs_alone :: proc(t: ^testing.T) {
	f: Kerned_Fixture
	if !kerned_start(t, &f) {return}
	defer kerned_stop(&f)
	pair := ui.text_width(&f.text, "To")
	first, second := ui.text_width(&f.text, "T"), ui.text_width(&f.text, "o")
	testing.expectf(t, pair < first + second, "\"To\" is %v wide, its glyphs %v and %v", pair, first, second)
	// The "o" lands where an "o" drawn alone at the kerned pen does, left of where it would without kerning.
	in_pair := last_glyph(t, &f, "To", 10)
	testing.expect_value(t, in_pair, last_glyph(t, &f, "o", 10 + pair - second))
	apart := last_glyph(t, &f, "o", 10 + first)
	testing.expectf(t, in_pair.x < apart.x, "kerned \"o\" at %v, unkerned at %v", in_pair.x, apart.x)
}

@(test)
kerned_text_that_fits_draws_whole_and_wraps_by_its_shaped_width :: proc(t: ^testing.T) {
	f: Kerned_Fixture
	if !kerned_start(t, &f) {return}
	defer kerned_stop(&f)
	// Exactly as wide as its shaped width, the text fits: every glyph draws and no ellipsis replaces any.
	render.draw_list_reset(&f.list)
	_ = render.push_layer(&f.list, {0, 0, 800, 100})
	width := ui.text_width(&f.text, "ToToTo")
	result := ui.draw_text(&f.text, &f.list, "ToToTo", 10, 50, {1, 1, 1, 1}, width)
	testing.expect_value(t, result, render.Build_Status.Ok)
	testing.expect_value(t, len(f.list.glyphs), 6)
	// A line as wide as "To To" holds it, though its glyphs side by side are wider.
	lines: [dynamic]string
	defer delete(lines)
	ui.wrap(&f.text, "To To To", ui.text_width(&f.text, "To To") + 0.25, &lines)
	if testing.expect_value(t, len(lines), 2) {
		testing.expect_value(t, lines[0], "To To")
		testing.expect_value(t, lines[1], "To")
	}
}

@(test)
wrap_drops_kerning_against_the_next_line_when_fitting_a_prefix :: proc(t: ^testing.T) {
	f: Kerned_Fixture
	if !kerned_start(t, &f) {return}
	defer kerned_stop(&f)
	value :: "0To"
	kerned_prefix := ui.text_width(&f.text, value) - ui.text_width(&f.text, "o")
	drawn_prefix := ui.text_width(&f.text, "0T")
	width := (kerned_prefix + drawn_prefix) / 2
	if !testing.expect(t, kerned_prefix < width && width < drawn_prefix) {return}
	lines: [dynamic]string
	defer delete(lines)
	ui.wrap(&f.text, value, width, &lines)
	if testing.expect_value(t, len(lines), 2) {
		testing.expect_value(t, lines[0], "0")
		testing.expect_value(t, lines[1], "To")
		for line in lines {testing.expect(t, ui.text_width(&f.text, line) <= width)}
	}
}

@(test)
wrap_keeps_hanging_spaces_and_advances_past_one_overwide_grapheme :: proc(t: ^testing.T) {
	f: Kerned_Fixture
	if !kerned_start(t, &f) {return}
	defer kerned_stop(&f)
	lines: [dynamic]string
	defer delete(lines)
	ui.wrap(&f.text, "0  T", ui.text_width(&f.text, "0"), &lines)
	if testing.expect_value(t, len(lines), 2) {
		testing.expect_value(t, lines[0], "0 ")
		testing.expect_value(t, lines[1], "T")
	}
	value :: "A\u0301B"
	ui.wrap(&f.text, value, ui.text_width(&f.text, "A\u0301") / 2, &lines)
	if testing.expect_value(t, len(lines), 2) {
		testing.expect_value(t, lines[0], "A\u0301")
		testing.expect_value(t, lines[1], "B")
	}
}

@(test)
wrap_keeps_a_grapheme_larger_than_its_shaping_scratch_whole :: proc(t: ^testing.T) {
	f: Kerned_Fixture
	if !kerned_start(t, &f) {return}
	defer kerned_stop(&f)
	bytes: [2 * (ui.CLIP_BYTES + 1) + 2]u8
	last := len(bytes) - 1
	bytes[0], bytes[last] = 'A', 'B'
	for i := 1; i < last; i += 2 {bytes[i], bytes[i + 1] = 0xCC, 0x81} // U+0301
	value := string(bytes[:])
	cluster_width := ui.text_width(&f.text, value[:last])
	if !testing.expect(t, cluster_width > 0) {return}
	lines: [dynamic]string
	defer delete(lines)
	ui.wrap(&f.text, value, cluster_width / 2, &lines)
	if testing.expect_value(t, len(lines), 2) {
		testing.expect_value(t, lines[0], value[:last])
		testing.expect_value(t, lines[1], "B")
	}
}

@(test)
warm_short_labels_measure_and_draw_without_temporary_allocation :: proc(t: ^testing.T) {
	f: Kerned_Fixture
	if !kerned_start(t, &f) {return}
	defer kerned_stop(&f)
	expected := last_glyph(t, &f, "OK", 0)
	width := ui.text_width(&f.text, "OK")
	render.draw_list_reset(&f.list)
	_ = render.push_layer(&f.list, {0, 0, 800, 100})
	allocator := context.temp_allocator
	context.temp_allocator = mem.nil_allocator()
	measured := ui.text_width(&f.text, "OK")
	drawn := ui.draw_text(&f.text, &f.list, "OK", 0, 50, {1, 1, 1, 1})
	context.temp_allocator = allocator
	testing.expect_value(t, measured, width)
	testing.expect_value(t, drawn, render.Build_Status.Ok)
	if testing.expect_value(t, len(f.list.glyphs), 2) {
		testing.expect_value(t, f.list.glyphs[1].rect, expected)
	}
}

@(test)
ellipsis_lookahead_keeps_held_glyphs_when_a_later_piece_fits :: proc(t: ^testing.T) {
	f: Kerned_Fixture
	if !kerned_start(t, &f) {return}
	defer kerned_stop(&f)
	bytes: [ui.CLIP_BYTES + 2]u8
	bytes[0], bytes[1] = 'W', 'A'
	for i := 2; i < ui.CLIP_BYTES; i += 2 {
		bytes[i], bytes[i + 1] = 0xCD, 0xB8 // U+0378; the first piece has only two drawn glyphs.
	}
	bytes[ui.CLIP_BYTES], bytes[ui.CLIP_BYTES + 1] = 'i', 'i'
	value := string(bytes[:])
	width := ui.text_width(&f.text, value)
	testing.expect(t, ui.text_width(&f.text, "WA") > width - ui.text_width(&f.text, ui.ELLIPSIS))
	_ = last_glyph(t, &f, value, 0)
	if !testing.expect_value(t, len(f.list.glyphs), 4) {return}
	expected := f.list.glyphs[1]
	render.draw_list_reset(&f.list)
	_ = render.push_layer(&f.list, {0, 0, 800, 100})
	result := ui.draw_text(&f.text, &f.list, value, 0, 50, {1, 1, 1, 1}, width)
	testing.expect_value(t, result, render.Build_Status.Ok)
	if testing.expect_value(t, len(f.list.glyphs), 4) {
		testing.expect_value(t, f.list.glyphs[1].atlas, expected.atlas)
		testing.expect_value(t, f.list.glyphs[1].rect, expected.rect)
	}
}

// The caret after a kerned glyph stands where the next glyph is drawn, and a click there finds it.
@(test)
a_field_caret_after_a_kerned_glyph_stands_at_the_next_drawn_glyph :: proc(t: ^testing.T) {
	f: Kerned_Fixture
	if !kerned_start(t, &f) {return}
	defer kerned_stop(&f)
	carets: ui.Carets
	f.text.carets = &carets
	carets.style = {shape = .Bar, stroke = 1}
	field: ui.Text_Field
	defer delete(field.bytes)
	ui.field_set(&field, "To")
	field.cursor, field.anchor = 1, 1
	ui.carets_begin(&carets, {}, render.frame_time_at(time.tick_add({}, time.Second)))
	render.draw_list_reset(&f.list)
	_ = render.push_layer(&f.list, {0, 0, 800, 100})
	result := ui.field_draw(&field, &f.list, &f.text, {}, 10, 50, 400, true, "", {1, 1, 1, 1})
	testing.expect_value(t, result, render.Build_Status.Ok)
	if !testing.expect(t, carets.claim.present && len(f.list.glyphs) == 2) {return}
	drawn := f.list.glyphs[1].rect
	at := carets.claim.paint.target.x
	testing.expect_value(t, at, 10 + ui.text_width(&f.text, "To") - ui.text_width(&f.text, "o"))
	testing.expectf(t, at < 10 + ui.text_width(&f.text, "T"), "the caret at %v ignores the kerning", at)
	testing.expect_value(t, drawn, last_glyph(t, &f, "o", at))
	testing.expect_value(t, ui.field_offset_at(&field, &f.text, 0, 10, at), 1)
}

@(test)
a_missing_cluster_has_no_advance_and_does_not_share_the_previous_glyph :: proc(t: ^testing.T) {
	f: Kerned_Fixture
	if !kerned_start(t, &f) {return}
	defer kerned_stop(&f)
	carets: ui.Carets
	f.text.carets = &carets
	carets.style = {shape = .Bar, stroke = 1}
	field: ui.Text_Field
	defer delete(field.bytes)
	ui.field_set(&field, "A\u0378B")
	a_width := ui.text_width(&f.text, "A")
	testing.expect_value(t, ui.text_width(&f.text, "A\u0378"), a_width)
	for offset in ([2]int{1, 3}) {
		field.cursor, field.anchor = offset, offset
		ui.carets_begin(&carets, {}, render.frame_time_at(time.tick_add({}, time.Second)))
		render.draw_list_reset(&f.list)
		_ = render.push_layer(&f.list, {0, 0, 800, 100})
		result := ui.field_draw(&field, &f.list, &f.text, {}, 10, 50, 400, true, "", {1, 1, 1, 1})
		testing.expect_value(t, result, render.Build_Status.Ok)
		if !testing.expect(t, carets.claim.present && len(f.list.glyphs) == 2) {return}
		testing.expect_value(t, carets.claim.paint.target.x, 10 + a_width)
	}
	testing.expect_value(t, ui.field_offset_at(&field, &f.text, 0, 10, 10 + a_width * 0.4), 0)
	testing.expect_value(t, ui.field_offset_at(&field, &f.text, 0, 10, 10 + a_width * 0.75), 1)
}

// An accent typed as a combining mark is one character with its letter: the caret, the pointer and
// Backspace never split them.
@(test)
a_field_caret_never_lands_inside_a_combining_sequence :: proc(t: ^testing.T) {
	fonts, err := font.system_create_private(test_fonts.files())
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, nil, 16, test_fonts.UI)) {return}
	field: ui.Text_Field
	defer delete(field.bytes)
	// "e", a combining acute (bytes 1 and 2), "x".
	value :: "e\u0301x"
	ui.field_set(&field, value)
	field.cursor, field.anchor = 0, 0
	ui.field_key(&field, {key = .Arrow_Right, pressed = true})
	testing.expect_value(t, field.cursor, 3)
	ui.field_key(&field, {key = .Arrow_Left, pressed = true})
	testing.expect_value(t, field.cursor, 0)
	width := ui.text_width(&text, value)
	for step in 0 ..= 40 {
		x := f32(step) * width / 40
		offset := ui.field_offset_at(&field, &text, 0, 0, x)
		testing.expectf(t, offset == 0 || offset == 3 || offset == 4, "a click at %v found offset %d", x, offset)
	}
	field.cursor, field.anchor = 3, 3
	testing.expect_value(t, ui.field_key(&field, {key = .Backspace, pressed = true}), ui.Field_Change.Edited)
	testing.expect_value(t, ui.field_string(&field), "x")
}
