package ui

import "core:math"
import "cosmos:input"
import "cosmos:render"

// A vertical viewport in window pixels. Layout supplies its current bounds and the height of its
// content. Content rects are local to the unscrolled origin; place them with scroll_viewport_place
// and clip both their drawing and hit testing to scroll_viewport_content.
Scroll_Viewport :: struct {
	bounds: render.Rect,
	content_height, offset: f32,
	drag: Scroll_Drag,
}

scroll_viewport_layout :: proc(v: ^Scroll_Viewport, bounds: render.Rect, content_height: f32) {
	v.bounds = bounds
	v.content_height = max(0, content_height)
	_ = scroll_viewport_to(v, v.offset)
	if scroll_viewport_limit(v^) == 0 {scroll_viewport_release(v)}
}

// The visible content area, excluding the scrollbar's track when the content overflows.
scroll_viewport_content :: proc(v: Scroll_Viewport, scale: f32) -> render.Rect {
	r := v.bounds
	if scroll_viewport_limit(v) > 0 {r.width = max(0, r.width - SCROLLBAR_TRACK * scale)}
	return r
}

scroll_viewport_place :: proc(v: Scroll_Viewport, local: render.Rect) -> render.Rect {
	return {v.bounds.x + local.x, v.bounds.y + local.y - v.offset, local.width, local.height}
}

// Scroll just far enough to show the item. An item taller than the viewport shows its leading edge.
scroll_viewport_reveal :: proc(v: ^Scroll_Viewport, local: render.Rect) -> bool {
	height := v.bounds.height
	if height <= 0 {return false}
	if local.y < v.offset || local.height >= height {return scroll_viewport_to(v, local.y)}
	if local.y + local.height > v.offset + height {return scroll_viewport_to(v, local.y + local.height - height)}
	return false
}

// Returns false at the edges so a caller can offer the wheel to an enclosing viewport. Call it only
// for the viewport that owns this event (e.g. not while a popover covers it).
scroll_viewport_wheel :: proc(
	v: ^Scroll_Viewport, e: input.Mouse_Wheel_Event, pixels_per_notch: f32,
) -> bool {
	if !render.rect_contains(v.bounds, f32(e.x), f32(e.y)) {return false}
	return scroll_viewport_to(v, v.offset - e.delta_y * pixels_per_notch)
}

scroll_viewport_bar :: proc(
	v: Scroll_Viewport, scale: f32, hovered: bool,
) -> (Scrollbar, Scrollbar_State, bool) {
	state := scrollbar_state(hovered, v.drag)
	visible := max(1, int(math.ceil(v.bounds.height)))
	limit := scroll_viewport_limit(v)
	range := int(math.ceil(limit))
	offset := v.offset > 0 && v.offset == limit ? range : int(math.round(v.offset))
	bar, shown := scrollbar_layout(v.bounds, {visible + range, visible, offset}, state, scale)
	return bar, state, shown
}

// Track presses page once or grab the thumb. The caller routes held moves and the matching release
// (including cancellation) to this viewport, even if the pointer leaves its bounds.
scroll_viewport_press :: proc(v: ^Scroll_Viewport, point: [2]f32, scale: f32) -> bool {
	bar, _, shown := scroll_viewport_bar(v^, scale, true)
	if !shown || !scrollbar_contains(bar, point.x, point.y) {return false}
	offset := scrollbar_press(&v.drag, bar, point.y)
	if !v.drag.active {_ = scroll_viewport_to(v, f32(offset))}
	return true
}

scroll_viewport_drag :: proc(v: ^Scroll_Viewport, y, scale: f32) -> bool {
	if !v.drag.active {return false}
	bar, _, shown := scroll_viewport_bar(v^, scale, true)
	return shown && scroll_viewport_to(v, f32(scrollbar_drag(v.drag, bar, y)))
}

scroll_viewport_release :: proc(v: ^Scroll_Viewport) {v.drag = {}}

@(private = "file")
scroll_viewport_limit :: proc(v: Scroll_Viewport) -> f32 {
	return max(0, v.content_height - max(0, v.bounds.height))
}

@(private = "file")
scroll_viewport_to :: proc(v: ^Scroll_Viewport, offset: f32) -> bool {
	next := clamp(offset, 0, scroll_viewport_limit(v^))
	if v.offset == next {return false}
	v.offset = next
	return true
}
