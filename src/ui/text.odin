package ui

import "cosmos:font"
import "cosmos:glyphs"
import "cosmos:render"
import "base:runtime"
import "core:log"
import "core:math"
import "core:slice"
import "core:unicode/utf8"

// The colours every widget draws with. Most are an app theme's roles; the hover, pressed, shadow,
// scrim and rim effects derive from them because they model light rather than name a role. An app
// whose views need more colours embeds this with `using` and passes the embedded Theme to widgets.
Theme :: struct {
	window, pane, surface, border, text, muted, faint, accent, accent_text: render.Color,
	selection, shadow, scrim, hover, pressed, focus, error, success, warning, info: render.Color,
	tab_bar, tab_text, tab_active, tab_active_text, tab_indicator, rail_active: render.Color,
	pane_border, pane_focus: render.Color,
	scrollbar_track, scrollbar, scrollbar_hover, scrollbar_active: render.Color,
	// The text cursor in every text surface, and the text under a block of it. Text selection is
	// filled with `text_selection`, and selected text takes `text_selection_text` when the theme sets
	// one.
	caret, caret_text, text_selection: render.Color,
	text_selection_text: Maybe(render.Color),
	// The shared raised-hover look. `rim` is the colour of the pointer-following edge light;
	// `hover_edge` is the hairline that holds a light fill's shape. Lift and gloss scale the raise and
	// its sheen, from 0 for none.
	rim:        render.Color,
	hover_edge: render.Color,
	hover_lift, hover_gloss: f32,
}

// Selawik is Microsoft's open substitute for Segoe UI, for a font system without the installed fonts.
@(private)
UI_FAMILIES :: [?]string{"Segoe UI Variable Text", "Segoe UI", "Selawik"}
@(private)
ICON_FAMILIES :: [?]string{"Segoe Fluent Icons", "Segoe MDL2 Assets"}
ELLIPSIS :: "…"

Text :: struct {
	fonts:                        ^font.System,
	cache:                        ^glyphs.Cache,
	family, strong_family, icons: font.Family,
	has_icons:                    bool,
	size_px, ascent, line_height: f32,
	// The window's field carets; nil draws every caret where it is.
	carets:                       ^Carets,
}

@(require_results)
text_init :: proc(
	t: ^Text, fonts: ^font.System, cache: ^glyphs.Cache, size_px: f32, preferred: string = "",
) -> bool {
	t.fonts, t.cache = fonts, cache
	for name in ([4]string{preferred, UI_FAMILIES[0], UI_FAMILIES[1], UI_FAMILIES[2]}) {
		if name == "" {continue}
		family, err := font.family_load(fonts, name)
		if err == .None {
			t.family, t.strong_family = family, family
			if strong, strong_error := font.family_load(fonts, name, true); strong_error == .None {
				t.strong_family = strong
			}
			for icon_name in ICON_FAMILIES {
				if icons, icon_error := font.family_load(fonts, icon_name); icon_error == .None {
					t.icons, t.has_icons = icons, true
					break
				}
			}
			text_set_size(t, size_px)
			return true
		}
	}
	return false
}

text_set_size :: proc(t: ^Text, size_px: f32) {
	m := font.face_metrics(t.fonts, t.family.faces[.Regular], size_px)
	t.size_px = size_px
	t.ascent = math.round(m.ascent)
	t.line_height = math.round(m.ascent + m.descent + m.line_gap)
}

// The baseline that centres `t`'s capitals, and so digits and most lowercase, on the middle of the band
// from `y` that is `height` tall. A line box centred on its ascent and descent sits capitals low, so a
// label beside an icon uses this to share the icon's centre line.
baseline_caps :: proc(y, height: f32, t: ^Text) -> f32 {
	m := font.face_metrics(t.fonts, t.family.faces[.Regular], t.size_px)
	return math.round(y + height / 2 + m.cap_height / 2)
}

text_width :: proc(t: ^Text, s: string) -> f32 {
	width: f32
	scratch: Shape_Scratch = ---
	for from := 0; from < len(s); {
		piece := shape_piece(t, s, from, &scratch)
		for g in piece.glyphs {width += g.advance}
		from = piece.end
	}
	return width
}

// Draws one line starting at the pen position on the baseline, as the font shapes it. A glyph takes
// `highlight` when the byte offset its cluster starts at appears in `highlights`; text wider than
// `max_width` (when positive) ends in an ellipsis, cut between clusters.
draw_text :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	s: string,
	x, baseline: f32,
	color: render.Color,
	max_width: f32 = 0,
	highlights: []int = nil,
	highlight: render.Color = {},
) -> render.Build_Status {
	limit := max_width > 0 ? max_width - text_width(t, ELLIPSIS) : max(f32)
	edge := max_width > 0 ? max_width : max(f32)
	pen := x
	next := 0
	// Clusters from the first one past `limit` are held back: the ellipsis takes their place if the text
	// turns out wider than `max_width`. Measuring stops at the first cluster past it, so a long string
	// is shaped no further than the piece that shows its end.
	cut_glyph := -1
	cut_pen: f32
	scratch: Shape_Scratch = ---
	piece: Shaped_Piece
	for from := 0; from < len(s); from = piece.end {
		piece = shape_piece(t, s, from, &scratch)
		for i := 0; i < len(piece.glyphs); {
			end, advance := cluster_glyphs(piece.glyphs, i)
			if cut_glyph < 0 && pen + advance - x > limit {
				cut_glyph, cut_pen = i, pen
			}
			if cut_glyph < 0 {
				result := draw_shaped(
					t, list, piece.glyphs[i:end], &pen, baseline, color, highlights, highlight, &next,
				)
				if result != .Ok {return result}
			} else {
				if pen + advance - x > edge {return draw_text(t, list, ELLIPSIS, cut_pen, baseline, color)}
				pen += advance
			}
			i = end
		}
		if cut_glyph >= 0 {break}
	}
	if cut_glyph < 0 {return .Ok}
	// Measure any later pieces separately so they cannot overwrite the held glyphs.
	if piece.end < len(s) && text_tail_exceeds(t, s, piece.end, pen, x, edge) {
		return draw_text(t, list, ELLIPSIS, cut_pen, baseline, color)
	}
	// The text fits after all, so draw the held clusters.
	pen = cut_pen
	rest := piece.glyphs[cut_glyph:]
	for {
		if result := draw_shaped(t, list, rest, &pen, baseline, color, highlights, highlight, &next);
		   result != .Ok {
			return result
		}
		if piece.end == len(s) {return .Ok}
		piece = shape_piece(t, s, piece.end, &scratch)
		rest = piece.glyphs
	}
}

@(private)
text_tail_exceeds :: proc(t: ^Text, s: string, from: int, pen, x, edge: f32) -> bool {
	scratch: Shape_Scratch = ---
	pen, from := pen, from
	for from < len(s) {
		piece := shape_piece(t, s, from, &scratch)
		for i := 0; i < len(piece.glyphs); {
			end, advance := cluster_glyphs(piece.glyphs, i)
			pen += advance
			if pen - x > edge {return true}
			i = end
		}
		from = piece.end
	}
	return false
}

// Draws shaped glyphs from the pen on the baseline and moves the pen on by their advances. `next` walks
// the sorted `highlights` along with the glyphs' clusters.
@(private)
draw_shaped :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	glyphs: []font.Shaped_Glyph,
	pen: ^f32,
	baseline: f32,
	color: render.Color,
	highlights: []int,
	highlight: render.Color,
	next: ^int,
) -> render.Build_Status {
	for g in glyphs {
		for next^ < len(highlights) && highlights[next^] < g.cluster {next^ += 1}
		c := next^ < len(highlights) && highlights[next^] == g.cluster ? highlight : color
		at := pen^ + g.offset.x
		if result := draw_glyph(t, list, g.glyph, at, baseline - g.offset.y, c); result != .Ok {return result}
		pen^ += g.advance
	}
	return .Ok
}

draw_glyph :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	g: font.Glyph,
	x, baseline: f32,
	c: render.Color,
) -> render.Build_Status {
	entry, result := glyphs.glyph(t.cache, g, t.size_px)
	if result != .Ok || entry.size.x == 0 {
		return result
	}
	left, top := math.round(x + entry.offset.x), math.round(baseline + entry.offset.y)
	at := render.Rect{left, top, entry.size.x, entry.size.y}
	_ = render.push_glyph(list, {rect = at, atlas = entry.atlas, color = c})
	return .Ok
}

// A piece of a line as the font sets it: its glyphs in drawing order, each glyph's cluster the byte offset
// in the line where its grapheme cluster starts, and the byte offsets where the piece's grapheme clusters
// start. The piece ends at byte `end`.
@(private)
Shaped_Piece :: struct {
	glyphs:    []font.Shaped_Glyph,
	graphemes: []int,
	end:       int,
}

@(private)
Shape_Scratch :: struct {
	runes:  [CLIP_BYTES]rune,
	ids:    [CLIP_BYTES]int,
	glyphs: [CLIP_BYTES]font.Shaped_Glyph,
}

// Shapes up to CLIP_BYTES from `from`, extending past it only to fit a single large grapheme.
// Glyphs live in `scratch` until it is reused. A caller laying out carets can supply `starts`
// for the grapheme byte offsets; drawing needs only the glyphs.
@(private)
shape_piece :: proc(
	t: ^Text, s: string, from: int, scratch: ^Shape_Scratch, starts: []int = nil,
) -> (piece: Shaped_Piece) {
	piece.end = len(s)
	runes, ids := scratch.runes[:], scratch.ids[:]
	n, count, end := 0, 0, from
	it := utf8.decode_grapheme_iterator_make(s[from:])
	for cluster, g in utf8.decode_grapheme_iterate(&it) {
		at := from + g.byte_index
		stop := at + len(cluster)
		if stop - from > CLIP_BYTES && end > from {break}
		if len(cluster) > CLIP_BYTES {
			need := utf8.rune_count_in_string(cluster)
			if need > len(runes) {
				rune_err, id_err: runtime.Allocator_Error
				runes, rune_err = make([]rune, need, context.temp_allocator)
				ids, id_err = make([]int, need, context.temp_allocator)
				if rune_err != nil || id_err != nil {
					log.error("ui: shaping text failed: out of memory")
					return
				}
			}
		}
		if starts != nil {
			starts[count] = at
			count += 1
		}
		for r in cluster {
			runes[n], ids[n] = r, at
			n += 1
		}
		end = stop
	}
	piece.graphemes, piece.end = starts[:count], end
	shaped := slice.into_dynamic(scratch.glyphs[:])
	err := font.shape(t.fonts, t.family, .Regular, runes[:n], t.size_px, &shaped, ids[:n], kern = true)
	if err == .Out_Of_Memory {
		// The fixed output buffer cannot grow. A large grapheme or a font expanding the input
		// into many more glyphs can spill; the completed shape is already in the font cache.
		shaped = make([dynamic]font.Shaped_Glyph, context.temp_allocator)
		err = font.shape(t.fonts, t.family, .Regular, runes[:n], t.size_px, &shaped, ids[:n], kern = true)
	}
	if err != .None {
		log.errorf("ui: shaping text failed: %v", err)
		return
	}
	for &g in shaped {
		g.cluster, g.source_last = ids[g.cluster], ids[g.source_last]
	}
	piece.glyphs = shaped[:]
	return
}

// The end of the glyphs from `i` on that share its cluster, and their advance together.
@(private)
cluster_glyphs :: proc(glyphs: []font.Shaped_Glyph, i: int) -> (end: int, advance: f32) {
	end = i
	for end < len(glyphs) && glyphs[end].cluster == glyphs[i].cluster {
		advance += glyphs[end].advance
		end += 1
	}
	return
}

// Advances the glyph cursor and returns how many graphemes share their advance.
@(private)
piece_cluster :: proc(piece: Shaped_Piece, at: int, glyph: ^int) -> (count: int, advance: f32) {
	start := piece.graphemes[at]
	count = 1
	if glyph^ == len(piece.glyphs) || piece.glyphs[glyph^].cluster != start {
		// Nothing in the source map reaches this grapheme, so it takes no room.
		return
	}
	last := start
	for glyph^ < len(piece.glyphs) && piece.glyphs[glyph^].cluster <= last {
		g := piece.glyphs[glyph^]
		last = max(last, g.source_last)
		advance += g.advance
		glyph^ += 1
	}
	for at + count < len(piece.graphemes) && piece.graphemes[at + count] <= last {count += 1}
	return
}

// Where the caret stands along one line of text as draw_text sets it, in temp memory. `x[i]` is how far
// from the line's start the caret stands before byte `i`, for every byte through the end of what was laid
// out; it is -1 inside a grapheme cluster, where no caret stops. A ligature over several clusters shares
// its advance evenly among them, as DirectWrite's own hit testing does.
@(private)
Text_Line :: struct {
	x: []f32,
}

// Lays out `s` for its carets, shaped as draw_text shapes it. Given a `width`, it stops after the piece
// that reaches past it, for a caller that never looks further right. Without memory it lays out nothing.
@(private)
text_line :: proc(t: ^Text, s: string, width := max(f32)) -> Text_Line {
	x := make([dynamic]f32, 0, min(len(s), CLIP_BYTES) + 1, context.temp_allocator)
	if _, err := line_fill(t, s, &x, 0, width); err != nil {
		log.errorf("ui: laying out text failed: %v", err)
		return {}
	}
	return {x[:]}
}

// Appends the caret positions of `s` laid out from `origin` to `x`, one per byte and one for its end, and
// returns the pen where it stopped: the end of `s`, or the end of the piece that reaches past `width`.
@(private, require_results)
line_fill :: proc(
	t: ^Text, s: string, x: ^[dynamic]f32, origin: f32, width := max(f32),
) -> (pen: f32, err: runtime.Allocator_Error) {
	base := len(x^)
	pen = origin
	from := 0
	scratch: Shape_Scratch = ---
	starts: [CLIP_BYTES]int = ---
	for from < len(s) && pen - origin <= width {
		piece := shape_piece(t, s, from, &scratch, starts[:])
		resize(x, base + piece.end) or_return
		slice.fill(x^[base + from:], -1)
		x^[base + from] = pen
		glyph := 0
		for k := 0; k < len(piece.graphemes); {
			n, advance := piece_cluster(piece, k, &glyph)
			for j in 0 ..< n {x^[base + piece.graphemes[k + j]] = pen + advance * f32(j) / f32(n)}
			pen += advance
			k += n
		}
		from = piece.end
	}
	_, err = append(x, pen)
	return
}

// The caret's x before byte `offset`: at the start of the cluster it falls in, and at the end of what
// was laid out when past it.
@(private)
text_line_x :: proc(line: Text_Line, offset: int) -> f32 {
	if len(line.x) == 0 {return 0}
	i := clamp(offset, 0, len(line.x) - 1)
	for i > 0 && line.x[i] < 0 {i -= 1}
	return line.x[i]
}

// The first caret stop after `offset`, or the end of what was laid out.
@(private)
text_line_next :: proc(line: Text_Line, offset: int) -> int {
	i := offset + 1
	for i < len(line.x) - 1 && line.x[i] < 0 {i += 1}
	return max(0, min(i, len(line.x) - 1))
}

// The last caret stop before `offset`, or the line's start.
@(private)
text_line_previous :: proc(line: Text_Line, offset: int) -> int {
	i := min(offset, len(line.x)) - 1
	for i > 0 && line.x[i] < 0 {i -= 1}
	return max(i, 0)
}

// The caret stop nearest to `x`: a point on the left half of a cluster is before it.
@(private)
text_line_offset_at :: proc(line: Text_Line, x: f32) -> int {
	at := 0
	for at < len(line.x) - 1 {
		next := text_line_next(line, at)
		if x < (line.x[at] + line.x[next]) / 2 {return at}
		at = next
	}
	return at
}

// Splits `s` into lines no wider than `width`, except lone graphemes and hanging trailing spaces.
wrap :: proc(t: ^Text, s: string, width: f32, out: ^[dynamic]string) {
	clear(out)
	lines := Wrap_Lines{text = t, s = s, width = width}
	for start, end in wrap_next(&lines) {append(out, s[start:end])}
}

// Walks the lines `wrap` splits a string into, without storing them.
// Initialize `text`, `s` and `width`; a zero `line_start` starts at the first byte.
Wrap_Lines :: struct {
	text:       ^Text,
	s:          string,
	width:      f32,
	line_start: int,
}

// A break space belongs to neither line. Other trailing spaces can hang past the width; only
// a non-space grapheme makes the line break. Each line is shaped afresh from its own start.
wrap_next :: proc(w: ^Wrap_Lines) -> (start, end: int, ok: bool) {
	start = w.line_start
	if start >= len(w.s) {return 0, 0, false}
	scratch: Shape_Scratch = ---
	starts: [CLIP_BYTES]int = ---
	pen: f32
	last_space := -1
	for from := start; from < len(w.s); {
		piece := shape_piece(w.text, w.s, from, &scratch, starts[:])
		after := pen
		for g in piece.glyphs {after += g.advance}
		fit := len(piece.graphemes)
		if after > w.width && fit > 0 {
			fit = wrap_fit(w, piece, from, pen, after, &scratch)
		}
		if fit == len(piece.graphemes) && piece.end == len(w.s) {break}
		if space := wrap_space(w, piece, from, pen, fit, &scratch); space >= 0 {
			last_space = space
		}
		if fit < len(piece.graphemes) {
			end = piece.graphemes[fit]
			w.line_start = end
			if last_space >= 0 {
				end, w.line_start = last_space, last_space + 1
			}
			return start, end, true
		}
		from, pen = piece.end, after
	}
	w.line_start = len(w.s)
	return start, len(w.s), true
}

// Glyph advances in a full piece give an estimate of the break. Verify it without the following
// text in the same piece: shaping can change at the new edge. All complete pieces to its left
// already match the renderer, so only this bounded piece needs reshaping.
@(private)
wrap_fit :: proc(
	w: ^Wrap_Lines, piece: Shaped_Piece, from: int, pen, after: f32, scratch: ^Shape_Scratch,
) -> int {
	count := len(piece.graphemes)
	guess := -1
	x, glyph := pen, 0
	estimate: for i := 0; i < count; {
		n, advance := piece_cluster(piece, i, &glyph)
		for j in 0 ..< n {
			at := i + j
			if wrap_is_space(w.s, piece, at) {continue}
			guess = at
			if x + advance * f32(j + 1) / f32(n) > w.width {break estimate}
		}
		x += advance
		i += n
	}
	if guess < 0 {return count}
	if wrap_grapheme_fits(w, piece, from, pen, after, guess, scratch) {
		for i in guess + 1 ..< count {
			if !wrap_is_space(w.s, piece, i) && !wrap_grapheme_fits(w, piece, from, pen, after, i, scratch) {
				return i
			}
		}
		return count
	}
	first_unfit := guess
	for i := guess - 1; i >= 0; i -= 1 {
		if wrap_is_space(w.s, piece, i) {continue}
		if wrap_grapheme_fits(w, piece, from, pen, after, i, scratch) {break}
		first_unfit = i
	}
	return first_unfit
}

@(private)
wrap_grapheme_fits :: proc(
	w: ^Wrap_Lines, piece: Shaped_Piece, from: int, pen, after: f32, i: int, scratch: ^Shape_Scratch,
) -> bool {
	if from == w.line_start && i == 0 {return true}
	if i + 1 == len(piece.graphemes) {return after <= w.width}
	return wrap_prefix_width(w, from, piece.graphemes[i + 1], pen, scratch) <= w.width
}

// The last usable word break among these graphemes. A different right edge can also make this
// earlier prefix wider, so check the visible portion again, without its hanging spaces.
@(private)
wrap_space :: proc(
	w: ^Wrap_Lines, piece: Shaped_Piece, from: int, pen: f32, fit: int, scratch: ^Shape_Scratch,
) -> int {
	for i := fit - 1; i >= 0; {
		space := piece.graphemes[i]
		if space <= w.line_start {break}
		if !wrap_is_space(w.s, piece, i) {
			i -= 1
			continue
		}
		trim := i
		for trim > 0 && wrap_is_space(w.s, piece, trim - 1) {trim -= 1}
		if trim == 0 || (from == w.line_start && trim == 1) ||
		   wrap_prefix_width(w, from, piece.graphemes[trim], pen, scratch) <= w.width {
			return space
		}
		i = trim - 1
	}
	return -1
}

@(private)
wrap_is_space :: proc(s: string, piece: Shaped_Piece, i: int) -> bool {
	at := piece.graphemes[i]
	end := i + 1 < len(piece.graphemes) ? piece.graphemes[i + 1] : piece.end
	// A space a mark sits on is a cluster of its own, not a place to break.
	return s[at] == ' ' && end == at + 1
}

@(private)
wrap_prefix_width :: proc(w: ^Wrap_Lines, from, end: int, pen: f32, scratch: ^Shape_Scratch) -> f32 {
	width := pen
	for g in shape_piece(w.text, w.s[:end], from, scratch).glyphs {width += g.advance}
	return width
}

draw_rect :: proc(list: ^render.Draw_List, instance: render.Rect_Instance) {
	_ = render.push_rect(list, instance)
}

// A widget that clips its own drawing opens a clip scope and closes it before returning, so its
// caller keeps drawing in the layer it was in. The list has no pop, so closing pushes that layer
// again.
@(private)
Clip_Scope :: struct {
	previous: render.Layer,
	restore:  bool,
}

clip_scope_open :: proc(list: ^render.Draw_List, clip: render.Rect, radius: f32 = 0) -> (Clip_Scope, bool) {
	scope: Clip_Scope
	if count := len(list.layers); count > 0 {scope = {list.layers[count - 1], true}}
	return scope, render.push_layer(list, clip, radius) == .None
}

clip_scope_close :: proc(list: ^render.Draw_List, scope: Clip_Scope) {
	if scope.restore {_ = render.push_layer(list, scope.previous.clip, scope.previous.radius)}
}

// The type ramp: four sizes and two weights. Body is the interface font size setting (13 DIPs by
// default); the other sizes keep their ratio to it. Hierarchy comes from size first, then weight,
// then the text colour roles, never from a size outside this ramp.
Text_Style :: enum {
	// Primary interface text: tabs, rows, menus, buttons, fields and palette results.
	Body,
	// Body emphasis: notice titles, group headings and the label of a primary or destructive button.
	Strong,
	// Secondary text: descriptions, paths, hints, counts, shortcuts and keycaps.
	Detail,
	// The title of a dialog or overlay, semibold.
	Title,
	// The one large element of a surface: the everything palette query and a page title.
	Display,
}

text_styled :: proc(t: ^Text, style: Text_Style) -> Text {
	copy := t^
	ratio := f32(1)
	switch style {
	case .Body, .Strong:
	case .Detail:
		ratio = 11.0 / 13
	case .Title:
		ratio = 15.0 / 13
	case .Display:
		ratio = 20.0 / 13
	}
	if style == .Strong || style == .Title {copy.family = t.strong_family}
	text_set_size(&copy, t.size_px * ratio)
	return copy
}

// The terminal's font at 0.9 of `t`'s size, as Markdown sets its code; for source text and diffs.
@(private = "file")
MONO_RATIO :: f32(0.9)

text_mono :: proc(t: ^Text, family: font.Family) -> Text {
	copy := t^
	copy.family, copy.strong_family = family, family
	text_set_size(&copy, t.size_px * MONO_RATIO)
	return copy
}

// Draws one line that fades out over its last fifth when wider than `width`. Glyphs take `highlight` as
// draw_text's do.
draw_fading_text :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	s: string,
	x, baseline: f32,
	color: render.Color,
	width: f32,
	highlights: []int = nil,
	highlight: render.Color = {},
) -> render.Build_Status {
	if width <= 0 {return .Ok}
	pen, edge := x, x + width
	first := len(list.glyphs)
	next := 0
	// Drawing stops at the first glyph past the edge, which also shows the text is wider than `width`.
	clipped := false
	scratch: Shape_Scratch = ---
	drawing: for from := 0; from < len(s); {
		piece := shape_piece(t, s, from, &scratch)
		for i in 0 ..< len(piece.glyphs) {
			if pen >= edge {
				clipped = true
				break drawing
			}
			result := draw_shaped(
				t, list, piece.glyphs[i:i + 1], &pen, baseline, color, highlights, highlight, &next,
			)
			if result != .Ok {return result}
		}
		from = piece.end
	}
	if clipped || pen > edge {
		for &glyph in list.glyphs[first:] {
			glyph.flags |= render.GLYPH_FADE
			glyph.fade_start, glyph.fade_end = x + width * 0.8, edge
		}
	}
	return .Ok
}

focus_ring_draw :: proc(list: ^render.Draw_List, rect: render.Rect, theme: Theme, scale: f32) {
	gap := render.Rect {
		rect.x - scale,
		rect.y - scale,
		rect.width + 2 * scale,
		rect.height + 2 * scale,
	}
	ring := render.Rect {
		rect.x - 3 * scale,
		rect.y - 3 * scale,
		rect.width + 6 * scale,
		rect.height + 6 * scale,
	}
	// The ring follows a control's corner outward: one DIP of gap, then two of ring.
	gap_radius, ring_radius := (RADIUS_CONTROL + 1) * scale, (RADIUS_CONTROL + 3) * scale
	draw_rect(list, {rect = gap, color = theme.window, radius = gap_radius, stroke = scale})
	draw_rect(list, {rect = ring, color = theme.accent, radius = ring_radius, stroke = 2 * scale})
}

// Centers the glyph's rasterized ink in `area`; draw_text instead places the pen on a baseline, which
// leaves symbols such as × visibly off center inside small buttons.
draw_glyph_centered :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	r: rune,
	area: render.Rect,
	c: render.Color,
) -> render.Build_Status {
	g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r)
	if !found {return .Ok}
	entry, result := glyphs.glyph(t.cache, g, t.size_px)
	if result != .Ok || entry.size.x == 0 {return result}
	at := render.Rect {
		math.round(area.x + (area.width - entry.size.x) / 2),
		math.round(area.y + (area.height - entry.size.y) / 2),
		entry.size.x,
		entry.size.y,
	}
	_ = render.push_glyph(list, {rect = at, atlas = entry.atlas, color = c})
	return .Ok
}

// Draws an icon-font glyph centered in `area` with the font at `size_px` pixels. Without an icon font
// nothing is drawn.
draw_icon :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	icon: rune,
	area: render.Rect,
	c: render.Color,
	size_px: f32,
) -> render.Build_Status {
	if !t.has_icons {return .Ok}
	icons := t^
	icons.family = t.icons
	text_set_size(&icons, size_px)
	return draw_glyph_centered(&icons, list, icon, area, c)
}

// Supply the whole emoji sequence to system fallback, including variation selectors and ZWJ.
draw_cluster_centered :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	cluster: string,
	area: render.Rect,
	c: render.Color,
	size_px: f32,
) -> render.Build_Status {
	runes: [32]rune
	clusters: [32]int
	count := 0
	for r in cluster {
		if count == len(runes) {return .Ok}
		runes[count] = r
		count += 1
	}
	if count == 0 || size_px <= 0 || area.width <= 0 || area.height <= 0 {return .Ok}
	// Cache hits append into bounded stack storage without per-icon scratch allocation.
	storage: [64]font.Shaped_Glyph
	shaped := slice.into_dynamic(storage[:])
	if err := font.shape(
		t.fonts,
		t.family,
		.Regular,
		runes[:count],
		size_px,
		&shaped,
		clusters[:count],
	); err != .None {
		log.errorf("ui: shaping an icon failed: %v", err)
		return .Ok
	}
	width: f32
	for g in shaped {width += g.advance}
	fit := width > 0 ? min(1, area.width / width) : 1
	draw_size := size_px * fit
	m := font.face_metrics(t.fonts, t.family.faces[.Regular], draw_size)
	baseline := math.round(area.y + (area.height - m.ascent - m.descent) / 2 + m.ascent)
	pen := area.x + (area.width - width * fit) / 2
	for g in shaped {
		entry, result := glyphs.glyph(t.cache, g.glyph, draw_size, foreground = c.rgb)
		if result != .Ok {return result}
		if entry.size.x > 0 {
			at := render.Rect {
				math.round(pen + g.offset.x * fit + entry.offset.x),
				math.round(baseline - g.offset.y * fit + entry.offset.y),
				entry.size.x,
				entry.size.y,
			}
			flags := entry.color ? render.GLYPH_COLOR : 0
			_ = render.push_glyph(
				list,
				{rect = at, atlas = entry.atlas, color = c, flags = flags},
			)
		}
		pen += g.advance * fit
	}
	return .Ok
}

// The baseline that centres one line of `t` in a row `height` tall starting at `y`.
baseline_in :: proc(y, height: f32, t: ^Text) -> f32 {return y + (height - t.line_height) / 2 + t.ascent}

// The most bytes of a title or path a row measures (see clip_bytes), and of a piece of text shaped at once.
CLIP_BYTES :: 512

// The start of `s` of at most `limit` bytes, cut on a rune boundary. Long titles and paths only ever show
// their start, so drawing never measures the rest.
clip_bytes :: proc(s: string, limit: int) -> string {
	if len(s) <= limit {return s}
	end := limit
	for end > 0 && (s[end] & 0xC0) == 0x80 {end -= 1}
	return s[:end]
}

// How many spaces a tab spans in code.
TAB_COLUMNS :: 4

// How wide a space is in `t`, which a tab spans TAB_COLUMNS times.
code_space :: proc(t: ^Text) -> f32 {
	if g, found := font.glyph_lookup(t.fonts, t.family, .Regular, ' '); found {
		return font.glyph_advance(t.fonts, g, t.size_px)
	}
	return 0
}

// How one rune of a code line lays out: a tab advances TAB_COLUMNS spaces from the pen and draws
// nothing, a rune without a glyph takes no room and draws nothing, and any other draws `glyph`. Painting,
// measuring and the hit test all read this, so they cannot disagree.
code_rune :: proc(t: ^Text, r: rune, space: f32) -> (glyph: font.Glyph, advance: f32, drawn: bool) {
	if r == '\t' {return {}, TAB_COLUMNS * space, false}
	g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r)
	if !found {return {}, 0, false}
	return g, font.glyph_advance(t.fonts, g, t.size_px), true
}
