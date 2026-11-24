package glyphs_test

import "core:testing"
import "cosmos:font"
import "cosmos:glyphs"
import "cosmos:render"
import "cosmos:test_fonts"

Fixture :: struct {
	fonts: ^font.System,
	device: ^render.Device,
	cache: glyphs.Cache,
	family: font.Family,
}

fixture_create :: proc(t: ^testing.T) -> (f: Fixture, ok: bool) {
	err: font.Error
	f.fonts, err = font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	f.family, err = font.family_load(f.fonts, "Consolas")
	device_error: render.Error
	f.device, device_error = render.device_create(.Warp)
	font_ok := testing.expect_value(t, err, font.Error.None)
	if !testing.expect_value(t, device_error, render.Error.None) || !font_ok {
		fixture_destroy(&f)
		return
	}
	glyphs.init(&f.cache, f.fonts, f.device)
	return f, true
}

fixture_destroy :: proc(f: ^Fixture) {
	glyphs.destroy(&f.cache)
	if f.device != nil {
		render.device_destroy(f.device)
	}
	if f.fonts != nil {
		font.system_destroy(f.fonts)
	}
}

@(test)
glyph_entries_are_cached :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	g, found := font.glyph_lookup(f.fonts, f.family, .Regular, 'A')
	if !testing.expect(t, found) {
		return
	}
	first, result := glyphs.glyph(&f.cache, g, 20)
	testing.expect_value(t, result, render.Build_Status.Ok)
	testing.expect(t, first.size.x > 0 && first.size.y > 0)
	testing.expect(t, first.offset.y < 0)
	again, _ := glyphs.glyph(&f.cache, g, 20)
	testing.expect_value(t, again, first)
	larger, _ := glyphs.glyph(&f.cache, g, 40)
	testing.expect(t, larger.size.y > first.size.y)
	space, _ := font.glyph_lookup(f.fonts, f.family, .Regular, ' ')
	empty, empty_result := glyphs.glyph(&f.cache, space, 20)
	testing.expect_value(t, empty_result, render.Build_Status.Ok)
	testing.expect_value(t, empty.size, [2]f32{})
}

@(test)
sprites_cover_the_cell_width :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	for kind in glyphs.Sprite {
		entry, result := glyphs.sprite(&f.cache, kind, 9, 2)
		testing.expect_value(t, result, render.Build_Status.Ok)
		testing.expect_value(t, entry.size, [2]f32{9, 8})
		testing.expect_value(t, entry.offset, [2]f32{0, -4})
		again, _ := glyphs.sprite(&f.cache, kind, 9, 2)
		testing.expect_value(t, again, entry)
	}
}

@(test)
atlas_reset_invalidates_entries :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	if !ok {
		return
	}
	defer fixture_destroy(&f)
	g, _ := font.glyph_lookup(f.fonts, f.family, .Regular, 'B')
	before, _ := glyphs.glyph(&f.cache, g, 24)
	for height in ([?]i32{256, 1}) {
		for {
			if _, reserved := render.atlas_reserve(f.device, 4096, height); !reserved {
				break
			}
		}
	}
	next, _ := font.glyph_lookup(f.fonts, f.family, .Regular, 'C')
	_, overflow := glyphs.glyph(&f.cache, next, 24)
	testing.expect_value(t, overflow, render.Build_Status.Atlas_Reset)
	after, result := glyphs.glyph(&f.cache, g, 24)
	testing.expect_value(t, result, render.Build_Status.Ok)
	testing.expect_value(t, after.size, before.size)
	testing.expect_value(t, after.atlas.x + after.atlas.y, 0)
}

// An emoji whose layers all name palette colours keeps one entry whatever ink it is drawn in, so
// animating a hover colour does not rasterize it again.
@(test)
palette_color_glyphs_share_one_entry_across_inks :: proc(t: ^testing.T) {
	fonts, err := font.system_create_private(test_fonts.files())
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	emoji, emoji_err := font.family_load(fonts, test_fonts.EMOJI)
	if !testing.expect_value(t, emoji_err, font.Error.None) {return}
	g, found := font.glyph_lookup(fonts, emoji, .Regular, 0x1f600)
	if !testing.expect(t, found) {return}
	device, device_err := render.device_create(.Warp)
	if !testing.expect_value(t, device_err, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	red, red_result := glyphs.glyph(&cache, g, 24, [3]f32{1, 0, 0})
	testing.expect_value(t, red_result, render.Build_Status.Ok)
	testing.expect(t, red.color && !red.foreground)
	blue, _ := glyphs.glyph(&cache, g, 24, [3]f32{0, 0, 1})
	testing.expect_value(t, blue, red)
	hits, misses := glyphs.glyph_counts(&cache)
	testing.expect_value(t, [2]u64{hits, misses}, [2]u64{1, 1})
}
