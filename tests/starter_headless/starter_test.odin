package starter_headless_test

import "core:math"
import "core:testing"
import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import starter "../../examples/starter"

// The headless platform and WARP: nothing opens on the desktop and the pixels are the same everywhere.
@(private = "file")
open :: proc(t: ^testing.T, s: ^starter.Starter) -> bool {
	return testing.expect(t, starter.starter_init(s, .Warp), "the starter did not start")
}

@(private = "file")
expect_color :: proc(t: ^testing.T, pixels: []u8, width: i32, x, y: f32, color: [4]f32, what: string) {
	index := (int(y) * int(width) + int(x)) * 4
	if !testing.expect(t, index + 4 <= len(pixels), what) {return}
	// The surface is BGRA.
	expected := [4]f32{color.b, color.g, color.r, color.a}
	for channel in 0 ..< 4 {
		actual := int(pixels[index + channel])
		wanted := int(math.round(expected[channel] * 255))
		testing.expectf(t, abs(actual - wanted) <= 2, "%s channel %d: got %d, expected %d", what, channel, actual, wanted)
	}
}

@(test)
frame_shows_the_renderers_viewer_under_its_marker :: proc(t: ^testing.T) {
	s: starter.Starter
	if !open(t, &s) {return}
	defer starter.starter_destroy(&s)
	starter.starter_frame(&s)
	pixels, err := render.surface_read_pixels(s.device, s.surface, context.allocator)
	if !testing.expect_value(t, err, render.Error.None) {return}
	defer delete(pixels)
	viewer := starter.viewer_rect(s.width, s.height)
	// Whole-pixel edges keep the ratio within a pixel of 16:9.
	testing.expect(t, abs(viewer.width - viewer.height * starter.VIEWER_ASPECT) <= 1, "viewer is not 16:9")
	middle := viewer.y + viewer.height / 2
	expect_color(t, pixels, s.width, viewer.x + viewer.width * 0.75, middle, starter.pattern_color(0), "viewer")
	expect_color(t, pixels, s.width, starter.marker_rect(viewer).x + 1, middle, starter.MARKER, "marker")
	expect_color(t, pixels, s.width, 4, 4, starter.BACKGROUND, "background")
}

@(test)
ctrl_o_opens_the_file_dialog_and_keeps_its_choice :: proc(t: ^testing.T) {
	s: starter.Starter
	if !open(t, &s) {return}
	defer starter.starter_destroy(&s)
	testing.expect_value(t, platform.file_pick_script(&s.desktop, `C:\clips\match.mp4`), platform.Error.None)
	starter.starter_event(&s, input.Key_Event{window = s.window, key = .O, modifiers = {.Control}, pressed = true})
	testing.expect(t, s.pick != nil, "Ctrl+O opened no dialog")
	starter.starter_poll_file(&s)
	testing.expect_value(t, s.chosen, `C:\clips\match.mp4`)
	testing.expect(t, s.pick == nil, "the finished dialog stayed open")
}
