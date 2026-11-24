package font

import "base:runtime"
import "core:math"

Style :: enum u8 {
	Regular,
	Bold,
	Italic,
	Bold_Italic,
}

Face_Id :: distinct u32

Family :: struct {
	faces: [Style]Face_Id,
}

Glyph :: struct {
	face:              Face_Id,
	index:             u16,
	scale, advance_em: f32,
}

Shaped_Glyph :: struct {
	glyph:   Glyph,
	cluster: int,
	advance: f32,
	offset:  [2]f32,
}

Face_Metrics :: struct {
	ascent, descent, line_gap:                       f32,
	underline_position, underline_thickness:         f32,
	strikethrough_position, strikethrough_thickness: f32,
	cap_height:                                      f32,
}

Bitmap :: struct {
	pixels:        []u8,
	width, height: i32,
	left, top:     i32,
	// Premultiplied RGBA when set; one coverage byte per pixel otherwise.
	color:         bool,
	// Some layers of the color glyph are drawn in the foreground it was rasterized with, so the
	// pixels hold only for that foreground.
	foreground:    bool,
}

// One layer of a color glyph: coverage over its pixel bounds, y down, drawn in color or, when
// foreground is set, in the text's color.
Color_Layer :: struct {
	coverage:                 []u8,
	left, top, right, bottom: i32,
	color:                    [4]f32,
	foreground:               bool,
}

Error :: enum {
	None,
	Out_Of_Memory,
	Invalid_Argument,
	Family_Not_Found,
	DirectWrite,
}

bitmap_destroy :: proc(bitmap: ^Bitmap, allocator: runtime.Allocator) {
	if bitmap != nil {
		delete(bitmap.pixels, allocator)
		bitmap^ = {}
	}
}

// Composites layers, bottom first, into premultiplied RGBA. Foreground layers take the foreground
// at full alpha, since the renderer fades the whole glyph by the text's opacity.
@(require_results)
color_layers_composite :: proc(
	layers: []Color_Layer,
	foreground: [3]f32,
	allocator: runtime.Allocator,
) -> (
	Bitmap,
	Error,
) {
	if len(layers) == 0 {
		return {}, .None
	}
	left, top, right, bottom := max(i32), max(i32), min(i32), min(i32)
	uses_foreground := false
	for layer in layers {
		assert(
			i64(len(layer.coverage)) ==
			(i64(layer.right) - i64(layer.left)) * (i64(layer.bottom) - i64(layer.top)),
		)
		left = min(left, layer.left)
		top = min(top, layer.top)
		right = max(right, layer.right)
		bottom = max(bottom, layer.bottom)
		if layer.foreground {uses_foreground = true}
	}
	width := i64(right) - i64(left)
	height := i64(bottom) - i64(top)
	if width > i64(max(i32)) ||
	   height > i64(max(i32)) ||
	   width * height > i64(max(u32)) / 4 ||
	   top == min(i32) {
		return {}, .Invalid_Argument
	}
	pixels, alloc_err := make([]u8, int(width * height * 4), allocator)
	if alloc_err != nil || pixels == nil {
		return {}, .Out_Of_Memory
	}
	// Source-over in premultiplied space, accumulated in floating point.
	accumulated, accumulated_err := make([][4]f32, int(width * height), allocator)
	if accumulated_err != nil || accumulated == nil {
		delete(pixels, allocator)
		return {}, .Out_Of_Memory
	}
	defer delete(accumulated, allocator)
	for layer in layers {
		color := layer.foreground ? [4]f32{foreground.r, foreground.g, foreground.b, 1} : layer.color
		w := int(layer.right - layer.left)
		dx := int(layer.left - left)
		dy := int(layer.top - top)
		for value, i in layer.coverage {
			if value == 0 {continue}
			a := f32(value) / 255 * color.a
			p := &accumulated[(dy + i / w) * int(width) + dx + i % w]
			p^ = {color.r * a, color.g * a, color.b * a, a} + p^ * (1 - a)
		}
	}
	for p, i in accumulated {
		for channel in 0 ..< 4 {
			pixels[i * 4 + channel] = u8(math.round(clamp(p[channel], 0, 1) * 255))
		}
	}
	return {
			pixels = pixels,
			width = i32(width),
			height = i32(height),
			left = left,
			top = -top,
			color = true,
			foreground = uses_foreground,
		},
		.None
}
