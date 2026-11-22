package render_test

import "core:testing"
import "cosmos:render"

@(test)
rect_fit_letterboxes_and_pillarboxes_on_whole_pixels :: proc(t: ^testing.T) {
	for row in ([?]struct {container, fitted: render.Rect, note: string} {
		{{0, 0, 1920, 1080}, {0, 0, 1920, 1080}, "exact"},
		{{0, 0, 1000, 1000}, {0, 219, 1000, 563}, "letterbox"},
		{{10, 20, 2000, 900}, {210, 20, 1600, 900}, "pillarbox, offset"},
		{{0, 0, 1001, 300}, {234, 0, 533, 300}, "odd width centres on a whole pixel"},
		{{0, 0, 0, 300}, {0, 0, 0, 0}, "empty"},
	}) {
		testing.expectf(t, render.rect_fit(row.container, 16.0 / 9) == row.fitted, "%s: got %v",
			row.note, render.rect_fit(row.container, 16.0 / 9))
	}
}
