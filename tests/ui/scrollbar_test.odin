package ui_test

import "core:time"
import "core:testing"
import "cosmos:render"
import "cosmos:ui"

@(test)
scrollbar_hides_when_content_fits_and_expands_under_pointer :: proc(t: ^testing.T) {
	area := render.Rect{0, 0, 100, 200}
	_, fits := ui.scrollbar_layout(area, {total = 10, visible = 10}, .Collapsed, 1)
	testing.expect(t, !fits)
	thin, visible := ui.scrollbar_layout(area, {total = 100, visible = 10, offset = 0}, .Collapsed, 1)
	testing.expect(t, visible)
	testing.expect_value(t, thin.track, render.Rect{90, 0, 10, 200})
	testing.expect_value(t, thin.thumb.y, f32(0))
	testing.expect(t, thin.thumb.height >= 24)
	wide, _ := ui.scrollbar_layout(area, {total = 100, visible = 10, offset = 90}, .Hovered, 1)
	testing.expect(t, wide.thumb.width > thin.thumb.width)
	testing.expect_value(t, wide.thumb.x + wide.thumb.width, thin.thumb.x + thin.thumb.width)
	testing.expect_value(t, wide.thumb.y + wide.thumb.height, f32(200))
	testing.expect_value(t, ui.scrollbar_state(false, {}), ui.Scrollbar_State.Collapsed)
	testing.expect_value(t, ui.scrollbar_state(true, {}), ui.Scrollbar_State.Hovered)
	testing.expect_value(t, ui.scrollbar_state(false, {active = true}), ui.Scrollbar_State.Active)
}

@(test)
scrollbar_track_pages_and_thumb_drags_clamped :: proc(t: ^testing.T) {
	bar, _ := ui.scrollbar_layout({0, 0, 100, 200}, {total = 100, visible = 10, offset = 40}, .Collapsed, 1)
	drag: ui.Scroll_Drag
	testing.expect_value(t, ui.scrollbar_press(&drag, bar, bar.thumb.y - 1), 30)
	testing.expect_value(t, ui.scrollbar_press(&drag, bar, bar.thumb.y + bar.thumb.height), 50)
	testing.expect(t, !drag.active)
	testing.expect_value(t, ui.scrollbar_press(&drag, bar, bar.thumb.y + 5), 40)
	testing.expect(t, drag.active && drag.grab == 5)
	testing.expect_value(t, ui.scrollbar_drag(drag, bar, -500), 0)
	testing.expect_value(t, ui.scrollbar_drag(drag, bar, 5000), 90)
	testing.expect_value(t, ui.scrollbar_drag(drag, bar, bar.thumb.y + 5), 40)
}

@(test)
scrollbar_page_pages_toward_the_pointer_and_stops_at_the_thumb :: proc(t: ^testing.T) {
	// Windows' own delays: the first repeat after 200 ms, then one every 50 ms.
	testing.expect_value(t, ui.SCROLLBAR_REPEAT_DELAY, 200 * time.Millisecond)
	testing.expect_value(t, ui.SCROLLBAR_REPEAT_INTERVAL, 50 * time.Millisecond)

	bar, _ := ui.scrollbar_layout({0, 0, 100, 200}, {total = 100, visible = 10, offset = 40}, .Collapsed, 1)
	x := bar.track.x + 2
	offset, result := ui.scrollbar_page(bar, x, bar.thumb.y - 1, .Before)
	testing.expect_value(t, offset, 30)
	testing.expect_value(t, result, ui.Scroll_Page.Paged)
	offset, result = ui.scrollbar_page(bar, x, bar.thumb.y + bar.thumb.height, .After)
	testing.expect_value(t, offset, 50)
	testing.expect_value(t, result, ui.Scroll_Page.Paged)
	// The thumb under the pointer: the view has met it, and nothing is held.
	offset, result = ui.scrollbar_page(bar, x, bar.thumb.y + 2, .Before)
	testing.expect_value(t, offset, 40)
	testing.expect_value(t, result, ui.Scroll_Page.On_Thumb)
	// A press that began below the thumb does not reverse when the pointer crosses above it: it pauses, as a
	// native scrollbar does, and pages again once the pointer is back below.
	offset, result = ui.scrollbar_page(bar, x, bar.thumb.y - 1, .After)
	testing.expect_value(t, offset, 40)
	testing.expect_value(t, result, ui.Scroll_Page.Off_Track)
	offset, result = ui.scrollbar_page(bar, x, bar.thumb.y + bar.thumb.height, .Before)
	testing.expect_value(t, result, ui.Scroll_Page.Off_Track)
	testing.expect_value(t, ui.scrollbar_side(bar, bar.thumb.y - 1), ui.Scroll_Side.Before)
	testing.expect_value(t, ui.scrollbar_side(bar, bar.thumb.y + 2), ui.Scroll_Side.None)
	// Off the track the page pauses, above and beside it alike.
	offset, result = ui.scrollbar_page(bar, bar.track.x - 1, bar.thumb.y - 1, .Before)
	testing.expect_value(t, offset, 40)
	testing.expect_value(t, result, ui.Scroll_Page.Off_Track)
	_, result = ui.scrollbar_page(bar, x, -1, .After)
	testing.expect_value(t, result, ui.Scroll_Page.Off_Track)
	// A view that cannot go further toward the pointer reports it rather than a page.
	stale := bar
	stale.extent.offset = 0
	offset, result = ui.scrollbar_page(stale, x, stale.thumb.y - 1, .Before)
	testing.expect_value(t, offset, 0)
	testing.expect_value(t, result, ui.Scroll_Page.Stuck)

	// Repeating toward a fixed pointer pages every time and stops with the thumb under it, from either
	// side, in the fewest whole pages; moving the pointer retargets it.
	area := render.Rect{0, 0, 100, 200}
	pointer := f32(120)
	view := 0
	for steps in 0 ..< 100 {
		b, _ := ui.scrollbar_layout(area, {total = 100, visible = 10, offset = view}, .Collapsed, 1)
		next, page := ui.scrollbar_page(b, x, pointer, .After)
		if page != .Paged {
			testing.expect_value(t, page, ui.Scroll_Page.On_Thumb)
			testing.expect(t, pointer >= b.thumb.y && pointer < b.thumb.y + b.thumb.height)
			testing.expect(t, steps > 1)
			break
		}
		testing.expect(t, next > view)
		view = next
		testing.expect(t, steps < 99)
	}
	pointer = 10
	before := view
	for _ in 0 ..< 100 {
		b, _ := ui.scrollbar_layout(area, {total = 100, visible = 10, offset = view}, .Collapsed, 1)
		next, page := ui.scrollbar_page(b, x, pointer, .Before)
		if page != .Paged {break}
		testing.expect(t, next < view)
		view = next
	}
	testing.expect(t, view < before)

	// A horizontal bar pages along x.
	wide, _ := ui.scrollbar_layout_horizontal({0, 0, 200, 100}, {total = 100, visible = 10, offset = 40}, .Collapsed, 1)
	y := wide.track.y + 2
	offset, result = ui.scrollbar_page(wide, wide.thumb.x - 1, y, .Before)
	testing.expect_value(t, offset, 30)
	testing.expect_value(t, result, ui.Scroll_Page.Paged)
	offset, result = ui.scrollbar_page(wide, wide.thumb.x + wide.thumb.width, y, .After)
	testing.expect_value(t, offset, 50)
	testing.expect_value(t, result, ui.Scroll_Page.Paged)
	_, result = ui.scrollbar_page(wide, wide.thumb.x + 2, y, .Before)
	testing.expect_value(t, result, ui.Scroll_Page.On_Thumb)
}
