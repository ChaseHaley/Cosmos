package render

import "core:math"

Color :: [4]f32

Rect :: struct {
	x, y, width, height: f32,
}

// Half-open containment: the left and top edges are inside, the right and bottom edges are not, so
// adjacent rectangles never both claim a point and an empty rectangle contains nothing.
rect_contains :: proc(r: Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

// Intersection of two half-open rectangles. Disjoint or empty axes have zero extent.
rect_intersect :: proc(a, b: Rect) -> Rect {
	left, top := max(a.x, b.x), max(a.y, b.y)
	right, bottom := min(a.x + a.width, b.x + b.width), min(a.y + a.height, b.y + b.height)
	return {left, top, max(0, right - left), max(0, bottom - top)}
}

// The largest rect of `aspect` (width over height) centred in `container`, with whole-pixel edges, as a
// video is letterboxed or pillarboxed in its viewer. An empty container or aspect gives an empty rect.
rect_fit :: proc(container: Rect, aspect: f32) -> Rect {
	if container.width <= 0 || container.height <= 0 || aspect <= 0 {return {container.x, container.y, 0, 0}}
	width := min(container.width, container.height * aspect)
	height := width / aspect
	return {
		math.round(container.x + (container.width - width) / 2),
		math.round(container.y + (container.height - height) / 2),
		math.round(width),
		math.round(height),
	}
}

// What drawing into a frame under construction reports. Atlas_Reset means the atlas was emptied
// to make room: every glyph and icon already placed in the frame is stale, so the caller stops
// drawing and lets Frame_Build start the next attempt.
Build_Status :: enum {
	Ok,
	Atlas_Reset,
}

Rect_Instance :: struct {
	rect:             Rect,
	color:            Color,
	radius, softness: f32,
	stroke:           f32,
	fill:             u32,
	// RECT_FILL_RIM only: local centre of the light, its reach, and the rim width, in pixels.
	sheen:            [4]f32,
}

// Rect_Instance and Glyph_Instance are read by draw.hlsl as StructuredBuffer elements, which pack
// four-byte scalars without padding. The shader's RectInstance and GlyphInstance list these fields
// in the same order.
#assert(size_of(Rect_Instance) == 64 && offset_of(Rect_Instance, fill) == 44)
#assert(offset_of(Rect_Instance, sheen) == 48)

// The fill and glyph flag values below reach draw.hlsl as same-named macros (see shader_macros), so
// the shader cannot drift from them.
//
// RECT_FILL_HUE_WHEEL shades a circle by hue around the center and saturation outward, with color.r as
// the HSV value. RECT_FILL_VALUE_RAMP darkens color.rgb to black at the left edge.
// RECT_FILL_RIM keeps color.rgb as a rim light: alpha follows a pointer-shaped reach at the rounded edge.
RECT_FILL_HUE_WHEEL :: u32(1)
RECT_FILL_VALUE_RAMP :: u32(2)
RECT_FILL_RIM :: u32(3)
// Round-capped strokes of width `stroke`. SEGMENT runs from sheen.xy to sheen.zw; ARC is centred on
// sheen.xy with `radius`, starting at angle sheen.z and sweeping sheen.w radians clockwise on screen.
// Both are in pixels local to `rect`, which must contain the stroke.
RECT_FILL_SEGMENT :: u32(4)
RECT_FILL_ARC :: u32(5)
// A soft shadow with its caster cut out: sheen holds the caster's rect (x, y, width, height) in pixels
// local to `rect`, and nothing is drawn inside it, so a see-through caster shows what is under it
// undarkened.
RECT_FILL_SHADOW :: u32(6)

// A glyph quad. Coverage glyphs are tinted with color; with GLYPH_COLOR set, the glyph samples the
// RGBA atlas and color.a only fades it.
Glyph_Instance :: struct {
	rect, atlas:          Rect,
	color:                Color,
	flags:                u32,
	fade_start, fade_end: f32,
	_:                    u32,
}

#assert(size_of(Glyph_Instance) == 64 && offset_of(Glyph_Instance, flags) == 48)

GLYPH_COLOR :: u32(1)
GLYPH_FADE :: u32(2)

// A textured quad. `key` names a texture from image_upload or image_render; `uv` is the part of it to
// show, in 0..1. A nonzero dust.progress draws it as dust instead; see Dust.
Image_Instance :: struct {
	rect, uv: Rect,
	key:      u64,
	dust:     Dust,
}

// An image crumbling to dust: each texel of the part `uv` shows is a grain, drawn `grain` pixels square
// at its place in `rect`. Grains leave from the bottom left toward the top right, along a ragged front
// whose shape `seed` picks; each turns to `ash`, then rises up to `rise` pixels while it thins out. At
// progress 1 every grain has gone.
Dust :: struct {
	progress, seed: f32,
	rise, grain:    f32,
	ash:            Color,
}

// Keys of the textures image_render draws. image_upload keys never set this bit or IMAGE_KEY_TARGET's,
// so they never collide.
IMAGE_KEY_RENDERED :: u64(1) << 63
// Keys of the textures image_target makes for a foreign renderer, such as a video player.
IMAGE_KEY_TARGET :: u64(1) << 62

// A layer draws its rects, then its images, then its glyphs. With `blur` set, it first blurs what is
// already drawn under its clip, as frosted glass: a gaussian with that standard deviation in pixels.
// The scissor limit, when present, is rectangular containment; clip and radius still describe
// this layer's own rounded mask, not a chain of ancestor masks.
Layer :: struct {
	clip:                                             Rect,
	radius:                                           f32,
	blur:                                             f32,
	scissored:                                        bool,
	scissor_limit:                                    Rect,
	rect_start, rect_count, glyph_start, glyph_count: int,
	image_start, image_count:                         int,
}

@(private)
Clip_Stack_Top :: struct {
	id:    u64,
	layer: int,
}

// A token from clip_push, to be passed back once, in LIFO order, on the same draw list.
Clip_Scope :: struct {
	list:   ^Draw_List,
	id:     u64,
	parent: Clip_Stack_Top,
}

Draw_List :: struct {
	layers: [dynamic]Layer,
	rects:  [dynamic]Rect_Instance,
	glyphs: [dynamic]Glyph_Instance,
	images: [dynamic]Image_Instance,
	// The first failed write invalidates the whole list until the next build.
	error: Error,
	// Completed frames belong to this atlas; zero leaves standalone lists unbound.
	atlas_generation: u64,
	// Resetting an attempt preserves diagnostics; only healthy completion rearms them.
	failure_reported: bool,
	clip_top:    Clip_Stack_Top,
	clip_serial: u64,
}

Atlas_Slot :: struct {
	x, y, width, height: i32,
	generation:          u64,
	color:               bool,
}

// Text_Gamma carries DirectWrite's grayscale text rendering parameters from font to the renderer.
Text_Gamma :: struct {
	gamma, enhanced_contrast: f32,
}

DEFAULT_TEXT_GAMMA :: Text_Gamma {
	gamma             = 1.8,
	enhanced_contrast = 1.0,
}

// The gamma range GAMMA_INCORRECT_TARGET_RATIOS covers, one row per tenth.
@(private)
MIN_TEXT_GAMMA :: 1
@(private)
MAX_TEXT_GAMMA :: 2.2

Error :: enum {
	None,
	Invalid_Argument,
	Out_Of_Memory,
	Device_Failed,
	Device_Lost,
	Shader_Failed,
	Surface_Failed,
	Wait_Failed,
	Atlas_Invalidated,
	Construction_Failed,
}

draw_list_init :: proc(allocator := context.allocator) -> Draw_List {
	return {
		layers = make([dynamic]Layer, allocator),
		rects = make([dynamic]Rect_Instance, allocator),
		glyphs = make([dynamic]Glyph_Instance, allocator),
		images = make([dynamic]Image_Instance, allocator),
	}
}

draw_list_reset :: proc(list: ^Draw_List) {
	clear(&list.layers)
	clear(&list.rects)
	clear(&list.glyphs)
	clear(&list.images)
	list.error = .None
	list.atlas_generation = 0
	list.clip_top = {}
}

draw_list_destroy :: proc(list: ^Draw_List) {
	delete(list.layers)
	delete(list.rects)
	delete(list.glyphs)
	delete(list.images)
	list^ = {}
}

// Copies recorded layers, not the source's live scopes. An active destination scope further
// restricts each copied layer's rectangular scissor without altering its own rounded mask.
@(require_results)
append_list :: proc(list: ^Draw_List, source: ^Draw_List) -> Error {
	if list.error != .None {return list.error}
	if source.error != .None {list.error = source.error; return list.error}
	if reserve(&list.layers, len(list.layers) + len(source.layers)) != nil ||
	   reserve(&list.rects, len(list.rects) + len(source.rects)) != nil ||
	   reserve(&list.glyphs, len(list.glyphs) + len(source.glyphs)) != nil ||
	   reserve(&list.images, len(list.images) + len(source.images)) != nil {
		list.error = .Out_Of_Memory
		return list.error
	}
	rect_offset, glyph_offset := len(list.rects), len(list.glyphs)
	image_offset := len(list.images)
	limit := active_clip(list)
	append(&list.rects, ..source.rects[:])
	append(&list.glyphs, ..source.glyphs[:])
	append(&list.images, ..source.images[:])
	for layer in source.layers {
		adjusted := layer
		adjusted.rect_start += rect_offset
		adjusted.glyph_start += glyph_offset
		adjusted.image_start += image_offset
		if list.clip_top.id != 0 {limit_layer(&adjusted, limit)}
		append(&list.layers, adjusted)
	}
	return .None
}

// Where drawing into a list stood, so a later pass can move or fade only what was drawn after it.
Draw_Mark :: struct {
	layers, rects, glyphs, images: int,
	clip_top:                      Clip_Stack_Top,
}

draw_mark :: proc(list: ^Draw_List) -> Draw_Mark {
	return {len(list.layers), len(list.rects), len(list.glyphs), len(list.images), list.clip_top}
}

// Moves everything drawn since `mark`, including its recorded clips, while keeping it inside `clip`.
draw_translate :: proc(list: ^Draw_List, mark: Draw_Mark, offset: [2]f32, clip: Rect) {
	for &layer in list.layers[mark.layers:] {
		layer.clip.x += offset.x
		layer.clip.y += offset.y
		if layer.scissored {
			layer.scissor_limit.x += offset.x
			layer.scissor_limit.y += offset.y
			layer.scissor_limit = rect_intersect(layer.scissor_limit, clip)
		} else {
			layer.clip = rect_intersect(layer.clip, clip)
		}
	}
	for &rect in list.rects[mark.rects:] {rect.rect.x += offset.x; rect.rect.y += offset.y}
	for &glyph in list.glyphs[mark.glyphs:] {
		glyph.rect.x += offset.x
		glyph.rect.y += offset.y
		glyph.fade_start += offset.x
		glyph.fade_end += offset.x
	}
	for &image in list.images[mark.images:] {image.rect.x += offset.x; image.rect.y += offset.y}
}

// Scales everything drawn since `mark` about `centre` by `factor`, as a surface growing or shrinking in
// place: positions, sizes, clips, corner radii and strokes alike, so its shapes keep their proportions.
draw_scale :: proc(list: ^Draw_List, mark: Draw_Mark, centre: [2]f32, factor: f32) {
	scaled :: proc(r: Rect, centre: [2]f32, factor: f32) -> Rect {
		x, y := centre.x + (r.x - centre.x) * factor, centre.y + (r.y - centre.y) * factor
		return {x, y, r.width * factor, r.height * factor}
	}
	for &layer in list.layers[mark.layers:] {
		layer.clip = scaled(layer.clip, centre, factor)
		if layer.scissored {layer.scissor_limit = scaled(layer.scissor_limit, centre, factor)}
		layer.radius *= factor
		layer.blur *= factor
	}
	for &rect in list.rects[mark.rects:] {
		rect.rect = scaled(rect.rect, centre, factor)
		rect.radius *= factor
		rect.softness *= factor
		rect.stroke *= factor
		// The sheen holds pixels local to the rect, but for an arc's last two, its angles.
		rect.sheen[0] *= factor
		rect.sheen[1] *= factor
		if rect.fill != RECT_FILL_ARC {rect.sheen[2] *= factor; rect.sheen[3] *= factor}
	}
	for &glyph in list.glyphs[mark.glyphs:] {
		glyph.rect = scaled(glyph.rect, centre, factor)
		glyph.fade_start = centre.x + (glyph.fade_start - centre.x) * factor
		glyph.fade_end = centre.x + (glyph.fade_end - centre.x) * factor
	}
	for &image in list.images[mark.images:] {
		image.rect = scaled(image.rect, centre, factor)
		image.dust.rise *= factor
		image.dust.grain *= factor
	}
}

// Appends what `source` drew between `from` and `to` to `list`, as a copy that outlives `source`'s next
// build. The range must start with a layer, so every instance in it belongs to one of its layers.
// As with append_list, only recorded layers are copied and an active destination scope bounds them.
@(require_results)
draw_list_copy :: proc(list: ^Draw_List, source: ^Draw_List, from, to: Draw_Mark) -> Error {
	if list.error != .None {return list.error}
	base := draw_mark(list)
	if _, err := append(&list.rects, ..source.rects[from.rects:to.rects]); err != nil {
		list.error = .Out_Of_Memory
	}
	if _, err := append(&list.glyphs, ..source.glyphs[from.glyphs:to.glyphs]); err != nil {
		list.error = .Out_Of_Memory
	}
	if _, err := append(&list.images, ..source.images[from.images:to.images]); err != nil {
		list.error = .Out_Of_Memory
	}
	limit := active_clip(list)
	for layer in source.layers[from.layers:to.layers] {
		copied := layer
		// Drawing after the range may have gone on into its last layer; the copy keeps only the range.
		copied.rect_count = clamp(to.rects - layer.rect_start, 0, layer.rect_count)
		copied.glyph_count = clamp(to.glyphs - layer.glyph_start, 0, layer.glyph_count)
		copied.image_count = clamp(to.images - layer.image_start, 0, layer.image_count)
		copied.rect_start += base.rects - from.rects
		copied.glyph_start += base.glyphs - from.glyphs
		copied.image_start += base.images - from.images
		if list.clip_top.id != 0 {limit_layer(&copied, limit)}
		if _, err := append(&list.layers, copied); err != nil {list.error = .Out_Of_Memory}
	}
	return list.error
}

// Forgets everything drawn since a mark from this list, restoring the scope active at the mark.
draw_list_truncate :: proc(list: ^Draw_List, mark: Draw_Mark) {
	resize(&list.layers, mark.layers)
	resize(&list.rects, mark.rects)
	resize(&list.glyphs, mark.glyphs)
	resize(&list.images, mark.images)
	list.clip_top = mark.clip_top
	if len(list.layers) == 0 {return}
	last := &list.layers[len(list.layers) - 1]
	last.rect_count = clamp(mark.rects - last.rect_start, 0, last.rect_count)
	last.glyph_count = clamp(mark.glyphs - last.glyph_start, 0, last.glyph_count)
	last.image_count = clamp(mark.images - last.image_start, 0, last.image_count)
}

@(private)
layer_clip :: proc(layer: ^Layer) -> Rect {
	if layer.scissored {return rect_intersect(layer.clip, layer.scissor_limit)}
	return layer.clip
}

@(private)
limit_layer :: proc(layer: ^Layer, limit: Rect) {
	layer.scissor_limit = layer.scissored ? rect_intersect(layer.scissor_limit, limit) : limit
	layer.scissored = true
}

@(private)
active_clip :: proc(list: ^Draw_List) -> Rect {
	if list.clip_top.id == 0 {return {}}
	return layer_clip(&list.layers[list.clip_top.layer])
}

// The current layer's effective rectangle, excluding the rounded mask.
clip_current :: proc(list: ^Draw_List) -> Rect {
	if len(list.layers) == 0 {return {}}
	return layer_clip(&list.layers[len(list.layers) - 1])
}

// Starts a rectangular scope inside the current layer. Its effective clip is the intersection
// with that layer's scissor. Layers pushed within the scope keep their own mask but cannot
// expand that scissor. Push and pop split batches, not the order of primitive types within one.
@(require_results)
clip_push :: proc(list: ^Draw_List, clip: Rect) -> (Clip_Scope, Error) {
	if list.error != .None {return {}, list.error}
	next := len(list.layers)
	if next == 0 {
		list.error = .Invalid_Argument
		return {}, list.error
	}
	layer := layer_continuation(&list.layers[next - 1])
	layer.scissor_limit = rect_intersect(layer_clip(&layer), clip)
	layer.scissored = true
	if err := append_layer(list, &layer); err != .None {return {}, err}
	list.clip_serial += 1
	scope := Clip_Scope{list, list.clip_serial, list.clip_top}
	list.clip_top = {scope.id, next}
	return scope, .None
}

// Restores the layer (including its rounded mask) from before clip_push, without replaying blur.
// A token from an earlier build or an out-of-order pop invalidates the current draw list.
@(require_results)
clip_pop :: proc(list: ^Draw_List, scope: Clip_Scope) -> Error {
	if list.error != .None {return list.error}
	if scope.list != list || scope.id == 0 || scope.id != list.clip_top.id {
		list.error = .Invalid_Argument
		return list.error
	}
	layer := layer_continuation(&list.layers[list.clip_top.layer - 1])
	if err := append_layer(list, &layer); err != .None {return err}
	list.clip_top = scope.parent
	return .None
}

@(private)
layer_continuation :: proc(previous: ^Layer) -> Layer {
	return {
		clip          = previous.clip,
		radius        = previous.radius,
		scissored     = previous.scissored,
		scissor_limit = previous.scissor_limit,
	}
}

// Pushes an absolute layer, bounded by the innermost rectangular scope when one is open.
@(require_results)
push_layer :: proc(list: ^Draw_List, clip: Rect, radius: f32 = 0) -> Error {
	if list.error != .None {return list.error}
	layer := Layer{clip = clip, radius = radius}
	if list.clip_top.id != 0 {limit_layer(&layer, active_clip(list))}
	return append_layer(list, &layer)
}

@(private, require_results)
append_layer :: proc(list: ^Draw_List, layer: ^Layer) -> Error {
	layer.rect_start = len(list.rects)
	layer.glyph_start = len(list.glyphs)
	layer.image_start = len(list.images)
	if _, err := append(&list.layers, layer^); err != nil {
		list.error = .Out_Of_Memory
	}
	return list.error
}

// Pushes a layer that blurs what is drawn under `clip` by a gaussian of standard deviation `sigma` pixels
// before its own content draws; see Layer.
@(require_results)
push_backdrop_blur :: proc(list: ^Draw_List, clip: Rect, sigma: f32, radius: f32 = 0) -> Error {
	if push_layer(list, clip, radius) != .None {return list.error}
	list.layers[len(list.layers) - 1].blur = sigma
	return .None
}

@(require_results)
push_rect :: proc(list: ^Draw_List, instance: Rect_Instance) -> Error {
	if list.error != .None {return list.error}
	assert(len(list.layers) > 0, "push_layer must precede push_rect")
	if _, err := append(&list.rects, instance); err != nil {
		list.error = .Out_Of_Memory
		return list.error
	}
	list.layers[len(list.layers) - 1].rect_count += 1
	return .None
}

@(require_results)
push_segment :: proc(list: ^Draw_List, a, b: [2]f32, width: f32, color: Color) -> Error {
	half := width / 2
	lo := [2]f32{min(a.x, b.x), min(a.y, b.y)} - half
	hi := [2]f32{max(a.x, b.x), max(a.y, b.y)} + half
	return push_rect(
		list,
		{
			rect = {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y},
			color = color,
			stroke = width,
			fill = RECT_FILL_SEGMENT,
			sheen = {a.x - lo.x, a.y - lo.y, b.x - lo.x, b.y - lo.y},
		},
	)
}

@(require_results)
push_arc :: proc(list: ^Draw_List, center: [2]f32, radius, start, sweep, width: f32, color: Color) -> Error {
	extent := radius + width / 2
	return push_rect(
		list,
		{
			rect = {center.x - extent, center.y - extent, 2 * extent, 2 * extent},
			color = color,
			radius = radius,
			stroke = width,
			fill = RECT_FILL_ARC,
			sheen = {extent, extent, start, sweep},
		},
	)
}

@(require_results)
push_glyph :: proc(list: ^Draw_List, instance: Glyph_Instance) -> Error {
	if list.error != .None {return list.error}
	assert(len(list.layers) > 0, "push_layer must precede push_glyph")
	if _, err := append(&list.glyphs, instance); err != nil {
		list.error = .Out_Of_Memory
		return list.error
	}
	list.layers[len(list.layers) - 1].glyph_count += 1
	return .None
}

// Appends draw commands kept from an earlier build to the current layer, moved by `offset`.
@(require_results)
push_instances :: proc(
	list: ^Draw_List,
	rects: []Rect_Instance,
	glyphs: []Glyph_Instance,
	offset: [2]f32,
) -> Error {
	if list.error != .None {return list.error}
	assert(len(list.layers) > 0, "push_layer must precede push_instances")
	if reserve(&list.rects, len(list.rects) + len(rects)) != nil ||
	   reserve(&list.glyphs, len(list.glyphs) + len(glyphs)) != nil {
		list.error = .Out_Of_Memory
		return list.error
	}
	rect_start, glyph_start := len(list.rects), len(list.glyphs)
	append(&list.rects, ..rects)
	append(&list.glyphs, ..glyphs)
	for &r in list.rects[rect_start:] {r.rect.x += offset.x; r.rect.y += offset.y}
	for &g in list.glyphs[glyph_start:] {
		g.rect.x += offset.x
		g.rect.y += offset.y
		// Only a fading glyph's bounds mean anything; others keep them zero, as drawn afresh.
		if g.flags & GLYPH_FADE != 0 {
			g.fade_start += offset.x
			g.fade_end += offset.x
		}
	}
	layer := &list.layers[len(list.layers) - 1]
	layer.rect_count += len(rects)
	layer.glyph_count += len(glyphs)
	return .None
}

@(require_results)
push_image :: proc(list: ^Draw_List, instance: Image_Instance) -> Error {
	if list.error != .None {return list.error}
	assert(len(list.layers) > 0, "push_layer must precede push_image")
	if _, err := append(&list.images, instance); err != nil {
		list.error = .Out_Of_Memory
		return list.error
	}
	list.layers[len(list.layers) - 1].image_count += 1
	return .None
}

@(private)
GAMMA_INCORRECT_TARGET_RATIOS :: [13][4]f32 {
	{0.0000 / 4, 0.0000 / 4, 0.0000 / 4, 0.0000 / 4},
	{0.0166 / 4, -0.0807 / 4, 0.2227 / 4, -0.0751 / 4},
	{0.0350 / 4, -0.1760 / 4, 0.4325 / 4, -0.1370 / 4},
	{0.0543 / 4, -0.2821 / 4, 0.6302 / 4, -0.1876 / 4},
	{0.0739 / 4, -0.3963 / 4, 0.8167 / 4, -0.2287 / 4},
	{0.0933 / 4, -0.5161 / 4, 0.9926 / 4, -0.2616 / 4},
	{0.1121 / 4, -0.6395 / 4, 1.1588 / 4, -0.2877 / 4},
	{0.1300 / 4, -0.7649 / 4, 1.3159 / 4, -0.3080 / 4},
	{0.1469 / 4, -0.8911 / 4, 1.4644 / 4, -0.3234 / 4},
	{0.1627 / 4, -1.0170 / 4, 1.6051 / 4, -0.3347 / 4},
	{0.1773 / 4, -1.1420 / 4, 1.7385 / 4, -0.3426 / 4},
	{0.1908 / 4, -1.2652 / 4, 1.8650 / 4, -0.3476 / 4},
	{0.2031 / 4, -1.3864 / 4, 1.9851 / 4, -0.3501 / 4},
}

// DirectWrite's fitted gamma correction, after microsoft/terminal src/renderer/atlas/dwrite.cpp (MIT).
gamma_ratios :: proc(gamma: f32) -> [4]f32 {
	NORM13 :: f32(f64(0x10000) / (255 * 255) * 4)
	NORM24 :: f32(f64(0x100) / 255 * 4)
	@(static, rodata)
	table := GAMMA_INCORRECT_TARGET_RATIOS
	index := int(math.round((clamp(gamma, MIN_TEXT_GAMMA, MAX_TEXT_GAMMA) - MIN_TEXT_GAMMA) * 10))
	r := table[index]
	return {NORM13 * r[0], NORM24 * r[1], NORM13 * r[2], NORM24 * r[3]}
}
