package ui_test

import "core:testing"
import "cosmos:input"
import "cosmos:render"
import "cosmos:ui"

@(test)
scroll_viewport_reveals_content_and_clamps_after_resize :: proc(t: ^testing.T) {
	v: ui.Scroll_Viewport
	ui.scroll_viewport_layout(&v, {20, 40, 100, 80}, 240)
	item := render.Rect{12, 190, 60, 20}
	testing.expect_value(t, ui.scroll_viewport_content(v, 1), render.Rect{20, 40, 90, 80})
	testing.expect(t, ui.scroll_viewport_reveal(&v, item))
	testing.expect_value(t, ui.scroll_viewport_place(v, item), render.Rect{32, 100, 60, 20})
	testing.expect(t, !ui.scroll_viewport_reveal(&v, item), "already visible content scrolled again")
	ui.scroll_viewport_layout(&v, {20, 40, 100, 180}, 240)
	testing.expect_value(t, v.offset, f32(60))
	ui.scroll_viewport_layout(&v, {20, 40, 100, 260}, 240)
	testing.expect_value(t, v.offset, f32(0))
	testing.expect_value(t, ui.scroll_viewport_content(v, 1), render.Rect{20, 40, 100, 260})
}

@(test)
scroll_viewport_wheel_passes_through_at_its_edges :: proc(t: ^testing.T) {
	v: ui.Scroll_Viewport
	ui.scroll_viewport_layout(&v, {20, 40, 100, 80}, 140)
	e := input.Mouse_Wheel_Event{x = 10, y = 80, delta_y = -1}
	testing.expect(t, !ui.scroll_viewport_wheel(&v, e, 36), "wheel outside the viewport was consumed")
	e.x = 90
	testing.expect(t, ui.scroll_viewport_wheel(&v, e, 36))
	testing.expect(t, ui.scroll_viewport_wheel(&v, e, 36))
	testing.expect_value(t, v.offset, f32(60))
	testing.expect(t, !ui.scroll_viewport_wheel(&v, e, 36), "outer viewport could not take the wheel")
	e.delta_y = 0.5
	testing.expect(t, ui.scroll_viewport_wheel(&v, e, 36))
	testing.expect_value(t, v.offset, f32(42))
}

@(test)
scroll_viewport_thumb_tracks_a_captured_drag_outside_its_bounds :: proc(t: ^testing.T) {
	v: ui.Scroll_Viewport
	ui.scroll_viewport_layout(&v, {20, 40, 100, 80}, 240)
	ui.scroll_viewport_press(&v, {115, 45}, 1)
	testing.expect(t, ui.scroll_viewport_drag(&v, 200, 1))
	testing.expect_value(t, v.offset, f32(160))
	ui.scroll_viewport_release(&v)
	testing.expect(t, !ui.scroll_viewport_drag(&v, 40, 1), "uncaptured drag scrolled the viewport")
}
