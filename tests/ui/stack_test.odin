package ui_test

import "core:math"
import "core:testing"
import "cosmos:render"
import "cosmos:ui"

@(test)
stack_fills_share_the_room_by_weight_inside_padding_and_spacing :: proc(t: ^testing.T) {
	s := ui.Stack{spacing = 4, padding = 5}
	items := [?]ui.Stack_Item{{size = 10}, {fill = 1}, {fill = 3}, {size = 10}}
	rects: [len(items)]render.Rect
	ui.stack_layout(s, {10, 20, 120, 30}, items[:], rects[:])
	// The content is 110 wide; sizes and spacing take 32, leaving 78 shared 1:3.
	testing.expect_value(t, rects[0], render.Rect{15, 25, 10, 20})
	testing.expect_value(t, rects[1], render.Rect{29, 25, 19.5, 20})
	testing.expect_value(t, rects[2], render.Rect{52.5, 25, 58.5, 20})
	testing.expect_value(t, rects[3], render.Rect{115, 25, 10, 20})

	// A fill grows from its size, and alignment does nothing while a fill takes the room.
	grown := [?]ui.Stack_Item{{size = 20, fill = 1}, {size = 10}}
	grown_rects: [len(grown)]render.Rect
	ui.stack_layout({align = .Center}, {0, 0, 100, 10}, grown[:], grown_rects[:])
	testing.expect_value(t, grown_rects[0], render.Rect{0, 0, 90, 10})
	testing.expect_value(t, grown_rects[1], render.Rect{90, 0, 10, 10})
}

@(test)
stack_aligns_a_run_that_nothing_fills :: proc(t: ^testing.T) {
	items := [?]ui.Stack_Item{{size = 20}, {size = 30}}
	rects: [len(items)]render.Rect
	cases := [ui.Stack_Align][2]f32 {
		.Start  = {0, 30},
		.Center = {20, 50},
		.End    = {40, 70},
	}
	for want, align in cases {
		ui.stack_layout({spacing = 10, align = align}, {0, 0, 100, 10}, items[:], rects[:])
		testing.expect_value(t, rects[0], render.Rect{want[0], 0, 20, 10})
		testing.expect_value(t, rects[1], render.Rect{want[1], 0, 30, 10})
	}
}

@(test)
stack_stretches_items_without_a_cross_size_and_aligns_the_rest :: proc(t: ^testing.T) {
	items := [?]ui.Stack_Item{{size = 10}, {size = 10, cross = 10}, {size = 10, cross = 100}}
	rects: [len(items)]render.Rect
	cases := [ui.Stack_Align]f32 {
		.Start  = 0,
		.Center = 15,
		.End    = 30,
	}
	for want, align in cases {
		ui.stack_layout({cross_align = align}, {0, 0, 100, 40}, items[:], rects[:])
		testing.expect_value(t, rects[0], render.Rect{0, 0, 10, 40})
		testing.expect_value(t, rects[1], render.Rect{10, want, 10, 10})
		// A cross size larger than the content is capped to it.
		testing.expect_value(t, rects[2], render.Rect{20, 0, 10, 40})
	}
}

// Sizes that exceed the room keep their lengths, fills get nothing, and the alignment decides which edge
// the run overflows; every rect is then clipped to the content.
@(test)
stack_overflow_keeps_sizes_and_clips_to_the_content :: proc(t: ^testing.T) {
	items := [?]ui.Stack_Item{{size = 20}, {fill = 1}, {size = 40}}
	rects: [len(items)]render.Rect
	ui.stack_layout({align = .Start}, {0, 0, 50, 10}, items[:], rects[:])
	testing.expect_value(t, rects[0], render.Rect{0, 0, 20, 10})
	testing.expect_value(t, rects[1], render.Rect{20, 0, 0, 10})
	testing.expect_value(t, rects[2], render.Rect{20, 0, 30, 10})
	ui.stack_layout({align = .End}, {0, 0, 50, 10}, items[:], rects[:])
	testing.expect_value(t, rects[0], render.Rect{0, 0, 10, 10})
	testing.expect_value(t, rects[1], render.Rect{10, 0, 0, 10})
	testing.expect_value(t, rects[2], render.Rect{10, 0, 40, 10})
	ui.stack_layout({align = .Center}, {0, 0, 50, 10}, items[:], rects[:])
	testing.expect_value(t, rects[0], render.Rect{0, 0, 15, 10})
	testing.expect_value(t, rects[1], render.Rect{15, 0, 0, 10})
	testing.expect_value(t, rects[2], render.Rect{15, 0, 35, 10})

	// An item pushed wholly outside becomes an empty rect on the edge it left by.
	pushed := [?]ui.Stack_Item{{size = 60}, {size = 10}, {size = 50}}
	pushed_rects: [len(pushed)]render.Rect
	ui.stack_layout({align = .End}, {0, 0, 50, 10}, pushed[:], pushed_rects[:])
	testing.expect_value(t, pushed_rects[0], render.Rect{0, 0, 0, 10})
	testing.expect_value(t, pushed_rects[1], render.Rect{0, 0, 0, 10})
	testing.expect_value(t, pushed_rects[2], render.Rect{0, 0, 50, 10})

	// Padding wider than the rect leaves an empty content in its middle rather than outside it.
	one := [?]ui.Stack_Item{{size = 4}}
	one_rect: [1]render.Rect
	ui.stack_layout({padding = 8}, {0, 0, 10, 10}, one[:], one_rect[:])
	testing.expect_value(t, one_rect[0], render.Rect{5, 5, 0, 0})
}

@(test)
stack_measure_is_the_length_its_items_fit_exactly :: proc(t: ^testing.T) {
	s := ui.Stack{spacing = 4, padding = 6, align = .End}
	items := [?]ui.Stack_Item{{size = 10}, {size = 20, fill = 1}, {size = 30}}
	length := ui.stack_measure(s, items[:])
	testing.expect_value(t, length, 80)
	rects: [len(items)]render.Rect
	ui.stack_layout(s, {0, 0, length, 20}, items[:], rects[:])
	testing.expect_value(t, rects[0], render.Rect{6, 6, 10, 8})
	testing.expect_value(t, rects[1], render.Rect{20, 6, 20, 8})
	testing.expect_value(t, rects[2], render.Rect{44, 6, 30, 8})
	testing.expect_value(t, ui.stack_measure(s, items[:1]), 22)
	testing.expect_value(t, ui.stack_measure(s, nil), 12)
}

@(test)
stack_row_nests_in_a_column_sized_to_its_measure :: proc(t: ^testing.T) {
	row := ui.Stack{spacing = 4, padding = 2}
	row_items := [?]ui.Stack_Item{{size = 30}, {size = 50}}
	column := ui.Stack{axis = .Column, spacing = 8, padding = 10, cross_align = .Center}
	column_items := [?]ui.Stack_Item{{size = 24, cross = ui.stack_measure(row, row_items[:])}, {fill = 1}}
	column_rects: [len(column_items)]render.Rect
	ui.stack_layout(column, {0, 0, 200, 100}, column_items[:], column_rects[:])
	testing.expect_value(t, column_rects[0], render.Rect{56, 10, 88, 24})
	testing.expect_value(t, column_rects[1], render.Rect{10, 42, 180, 48})
	row_rects: [len(row_items)]render.Rect
	ui.stack_layout(row, column_rects[0], row_items[:], row_rects[:])
	testing.expect_value(t, row_rects[0], render.Rect{58, 12, 30, 20})
	testing.expect_value(t, row_rects[1], render.Rect{92, 12, 50, 20})
}

@(test)
stack_with_no_items_lays_out_nothing :: proc(t: ^testing.T) {
	ui.stack_layout({padding = 4}, {0, 0, 100, 10}, nil, nil)
	testing.expect_value(t, ui.stack_measure({spacing = 8, padding = 4}, nil), 8)
}

// Rects are not rounded to whole pixels: fractional sizes pass through, fill shares stay fractional, and
// the last fill still ends on the content's edge.
@(test)
stack_keeps_fractional_pixels :: proc(t: ^testing.T) {
	items := [?]ui.Stack_Item{{fill = 1}, {fill = 1}, {fill = 1}, {size = 10.25}}
	rects: [len(items)]render.Rect
	ui.stack_layout({}, {0, 0, 110.25, 10}, items[:], rects[:])
	for r in rects[:3] {
		testing.expect(t, abs(r.width - 100.0 / 3) < 1e-4)
		testing.expect(t, r.width != math.round(r.width))
	}
	testing.expect_value(t, rects[0].x, 0)
	testing.expect(t, abs(rects[2].x + rects[2].width - 100) < 1e-4)
	testing.expect_value(t, rects[3], render.Rect{100, 0, 10.25, 10})
}
