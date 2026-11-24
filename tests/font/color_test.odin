package font_test

import "core:testing"
import "cosmos:font"

pixel :: proc(bitmap: font.Bitmap, i: int) -> [4]u8 {
	p := bitmap.pixels[i * 4:]
	return {p[0], p[1], p[2], p[3]}
}

// A layer in the text colour takes the foreground where it covers, and a palette layer under it
// keeps its own colour where it shows.
@(test)
foreground_layers_take_the_text_colour :: proc(t: ^testing.T) {
	palette := [2]u8{255, 255}
	text := [2]u8{255, 255}
	layers := [2]font.Color_Layer {
		{coverage = palette[:], left = 0, top = -1, right = 2, bottom = 0, color = {1, 0, 0, 1}},
		{coverage = text[:], left = 1, top = -1, right = 3, bottom = 0, foreground = true},
	}
	bitmap, err := font.color_layers_composite(layers[:], {0, 0, 1}, context.allocator)
	defer font.bitmap_destroy(&bitmap, context.allocator)
	if !testing.expect_value(t, err, font.Error.None) {return}
	testing.expect(t, bitmap.color && bitmap.foreground)
	placement := [4]i32{bitmap.width, bitmap.height, bitmap.left, bitmap.top}
	testing.expect_value(t, placement, [4]i32{3, 1, 0, 1})
	if !testing.expect_value(t, len(bitmap.pixels), 12) {return}
	testing.expect_value(t, pixel(bitmap, 0), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel(bitmap, 1), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, pixel(bitmap, 2), [4]u8{0, 0, 255, 255})
}

// With only palette layers the pixels do not depend on the foreground, so a cache may share them.
@(test)
palette_layers_ignore_the_foreground :: proc(t: ^testing.T) {
	coverage := [1]u8{128}
	layers := [1]font.Color_Layer{{coverage = coverage[:], right = 1, bottom = 1, color = {0, 1, 0, 1}}}
	bitmap, err := font.color_layers_composite(layers[:], {1, 0, 1}, context.allocator)
	defer font.bitmap_destroy(&bitmap, context.allocator)
	if !testing.expect_value(t, err, font.Error.None) {return}
	testing.expect(t, !bitmap.foreground)
	if !testing.expect_value(t, len(bitmap.pixels), 4) {return}
	testing.expect_value(t, pixel(bitmap, 0), [4]u8{0, 128, 0, 128})
}
