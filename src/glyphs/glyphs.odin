package glyphs

import "cosmos:font"
import "cosmos:render"
import "base:runtime"
import "core:log"
import "core:math"

Sprite :: enum u8 {
	Curly_Underline,
	Dotted_Underline,
	Dashed_Underline,
}

// Where a glyph or sprite sits in the atlas and how to place it relative to the pen position on the baseline.
Entry :: struct {
	atlas:      render.Rect,
	offset:     [2]f32,
	size:       [2]f32,
	// The atlas rect is in the RGBA atlas and the glyph draws in its own colors.
	color:      bool,
	// Some of the color glyph's layers are drawn in the foreground it was asked for.
	foreground: bool,
}

Cache :: struct {
	allocator:  runtime.Allocator,
	fonts:      ^font.System,
	device:     ^render.Device,
	glyphs:     map[Glyph_Key]Entry,
	sprites:    map[Sprite_Key]Entry,
	// Recent glyphs by key hash, checked before the map: a frame looks a glyph up once per drawn
	// cell, and a map probe per cell cost more than the rest of placing it.
	front:      [FRONT_SLOTS]Front_Slot,
	generation: u64,
	hits:       u64,
	misses:     u64,
}

@(private)
FRONT_SLOTS :: 1024

@(private)
Front_Slot :: struct {
	key:   Glyph_Key,
	entry: Entry,
	used:  bool,
}

@(private)
Glyph_Key :: struct {
	face:       font.Face_Id,
	index:      u16,
	size_q:     u32,
	color:      bool,
	// Set only for a color glyph whose layers use the text color, which is cached once per quantized
	// foreground; any other glyph has one entry whatever color it is drawn in.
	tinted:     bool,
	foreground: [3]u8,
}

@(private)
Sprite_Key :: struct {
	sprite:                   Sprite,
	width, height, thickness: u16,
}

@(private)
front_slot :: proc(c: ^Cache, key: Glyph_Key) -> ^Front_Slot {
	h :=
		u64(key.face) << 48 | u64(key.index) << 32 | u64(key.size_q) << 2 | u64(key.tinted) << 1 |
		u64(key.color)
	h ~= u64(key.foreground.r) << 40 | u64(key.foreground.g) << 32 | u64(key.foreground.b) << 24
	return &c.front[(h * 0x9E3779B97F4A7C15) >> 54]
}

@(private)
lookup :: proc(c: ^Cache, key: Glyph_Key) -> (Entry, bool) {
	slot := front_slot(c, key)
	if slot.used && slot.key == key {
		return slot.entry, true
	}
	entry, found := c.glyphs[key]
	if found {
		slot^ = {key, entry, true}
	}
	return entry, found
}

@(private)
remember :: proc(c: ^Cache, key: Glyph_Key, entry: Entry) {
	c.glyphs[key] = entry
	front_slot(c, key)^ = {key, entry, true}
}

init :: proc(
	c: ^Cache,
	fonts: ^font.System,
	device: ^render.Device,
	allocator := context.allocator,
) {
	c^ = {
		allocator  = allocator,
		fonts      = fonts,
		device     = device,
		glyphs     = make(map[Glyph_Key]Entry, allocator),
		sprites    = make(map[Sprite_Key]Entry, allocator),
		generation = render.atlas_generation(device),
	}
}

destroy :: proc(c: ^Cache) {
	delete(c.glyphs)
	delete(c.sprites)
	c^ = {}
}

// Points the cache at a new device after device loss; every entry belongs to the old atlas.
reset_device :: proc(c: ^Cache, device: ^render.Device) {
	c.device = device
	forget(c)
}

@(private)
forget :: proc(c: ^Cache) {
	clear(&c.glyphs)
	clear(&c.sprites)
	c.front = {}
	c.generation = render.atlas_generation(c.device)
}

@(private)
validate :: proc(c: ^Cache) {
	if c.generation != render.atlas_generation(c.device) {
		forget(c)
	}
}

// Places pixels in the atlas. When the atlas is full it is reset, every entry is forgotten, and the
// caller must rebuild the frame because entries it already used are stale.
@(private)
upload :: proc(
	c: ^Cache,
	width, height: i32,
	pixels: []u8,
	color := false,
) -> (
	render.Rect,
	render.Build_Status,
) {
	slot: render.Atlas_Slot
	rect, status := render.atlas_ensure(c.device, &slot, width, height, pixels, int(width), color)
	if status != .Ok {
		forget(c)
	}
	return rect, status
}

// Given a foreground (the text's RGB), a glyph the font draws in color is cached as RGBA and its
// entry reports color. Its entry under the colorless key says whether its layers use the
// foreground; only then is it looked up again per quantized foreground, so emoji drawn in many
// inks keep one entry.
glyph :: proc(
	c: ^Cache,
	g: font.Glyph,
	size_px: f32,
	foreground: Maybe([3]f32) = nil,
) -> (
	Entry,
	render.Build_Status,
) {
	validate(c)
	ink, color := foreground.?
	key := Glyph_Key {
		face   = g.face,
		index  = g.index,
		size_q = u32(math.round(size_px * g.scale * 64)),
		color  = color,
	}
	entry, found := lookup(c, key)
	if found && !entry.foreground {
		c.hits += 1
		return entry, .Ok
	}
	tinted_key := key
	tinted_key.tinted = true
	tinted_key.foreground = {
		u8(math.round(clamp(ink.r, 0, 1) * 255)),
		u8(math.round(clamp(ink.g, 0, 1) * 255)),
		u8(math.round(clamp(ink.b, 0, 1) * 255)),
	}
	if found {
		key = tinted_key
		entry, found = lookup(c, key)
		if found {
			c.hits += 1
			return entry, .Ok
		}
	}
	c.misses += 1
	rasterized: Maybe([3]f32)
	if color {
		q := tinted_key.foreground
		rasterized = [3]f32{f32(q.r), f32(q.g), f32(q.b)} / 255
	}
	bitmap, err := font.glyph_rasterize(c.fonts, g, size_px, c.allocator, rasterized)
	if err != .None {
		log.errorf("glyphs: rasterizing glyph %v of face %v failed: %v", g.index, g.face, err)
		remember(c, key, {})
		return {}, .Ok
	}
	defer font.bitmap_destroy(&bitmap, c.allocator)
	if bitmap.width > 0 && bitmap.height > 0 {
		rect, result := upload(c, bitmap.width, bitmap.height, bitmap.pixels, bitmap.color)
		if result != .Ok {
			return {}, result
		}
		entry = {
			atlas      = rect,
			offset     = {f32(bitmap.left), -f32(bitmap.top)},
			size       = {f32(bitmap.width), f32(bitmap.height)},
			color      = bitmap.color,
			foreground = bitmap.foreground,
		}
	}
	remember(c, key, entry)
	if entry.foreground && !key.tinted {
		remember(c, tinted_key, entry)
	}
	return entry, .Ok
}

// glyph_counts reports glyph() atlas lookups since the cache was created: hits reused an entry,
// misses rasterized and uploaded one. Sprites (underline decorations) are not counted. Rendering
// owns both counters, so a diagnostics read needs no lock.
@(require_results)
glyph_counts :: proc(c: ^Cache) -> (hits, misses: u64) {
	return c.hits, c.misses
}

// reset_counts clears the lookup totals for a diagnostics reset.
reset_counts :: proc(c: ^Cache) {
	c.hits, c.misses = 0, 0
}

// Returns a cell-wide decoration; its offset centers it vertically on the pen position.
sprite :: proc(c: ^Cache, kind: Sprite, cell_width, thickness: f32) -> (Entry, render.Build_Status) {
	validate(c)
	t := max(1, u16(math.round(thickness)))
	w := max(1, u16(cell_width))
	h := t * 4
	key := Sprite_Key{kind, w, h, t}
	if entry, found := c.sprites[key]; found {
		return entry, .Ok
	}
	pixels := make([]u8, int(w) * int(h), context.temp_allocator)
	draw_sprite(kind, int(w), int(h), f32(t), pixels)
	rect, result := upload(c, i32(w), i32(h), pixels)
	if result != .Ok {
		return {}, result
	}
	entry := Entry {
		atlas  = rect,
		offset = {0, -f32(h) / 2},
		size   = {f32(w), f32(h)},
	}
	c.sprites[key] = entry
	return entry, .Ok
}

@(private)
draw_sprite :: proc(kind: Sprite, width, height: int, thickness: f32, pixels: []u8) {
	center := f32(height) / 2
	switch kind {
	case .Curly_Underline:
		amplitude := center - thickness / 2 - 0.5
		for y in 0 ..< height {
			for x in 0 ..< width {
				phase := (f32(x) + 0.5) / f32(width) * 2 * math.PI
				curve := center + amplitude * math.sin(phase)
				distance :=
					abs(f32(y) + 0.5 - curve) *
					math.cos(math.atan(amplitude * 2 * math.PI / f32(width)))
				coverage := clamp(thickness / 2 + 0.5 - distance, 0, 1)
				pixels[y * width + x] = u8(coverage * 255)
			}
		}
	case .Dotted_Underline, .Dashed_Underline:
		top := int(center - thickness / 2)
		segment := kind == .Dotted_Underline ? max(1, int(thickness)) : max(2, width / 3)
		for y in top ..< min(height, top + int(thickness)) {
			for x in 0 ..< width {
				on := (x / segment) % 2 == 0
				pixels[y * width + x] = on ? 255 : 0
			}
		}
	}
}
