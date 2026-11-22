package ui_test

import "cosmos:ui"
import "core:testing"
import "core:time"

@(private = "file")
after :: proc(start: time.Tick, d: time.Duration) -> time.Tick {
	return time.tick_add(start, d)
}

// A label waits TOOLTIP_DELAY; once one showed, a neighbour's shows at once, but not after the grace or
// from far away.
@(test)
tooltip_waits_then_stays_warm_for_neighbours :: proc(t: ^testing.T) {
	s: ui.Tooltip_State
	start := time.tick_now()
	testing.expect(t, ui.tooltip_hover(&s, "Minimize", {10, 10}, 1, start, false))
	testing.expect_value(t, ui.tooltip_current(&s), "Minimize")
	testing.expect(t, !ui.tooltip_tick(&s, after(start, ui.TOOLTIP_DELAY - time.Millisecond)))
	_, shown := ui.tooltip_shown(&s)
	testing.expect(t, !shown, "not before the delay")
	deadline, pending := ui.tooltip_deadline(&s)
	testing.expect(t, pending && deadline == after(start, ui.TOOLTIP_DELAY))
	testing.expect(t, ui.tooltip_tick(&s, deadline))
	label, visible := ui.tooltip_shown(&s)
	testing.expect(t, visible && label == "Minimize")

	left := after(deadline, 100 * time.Millisecond)
	testing.expect(t, ui.tooltip_hover(&s, "", {30, 10}, 1, left, false), "leaving warms it")
	testing.expect(t, ui.tooltip_hover(&s, "Maximize", {50, 10}, 1, after(left, 10 * time.Millisecond), false))
	label, visible = ui.tooltip_shown(&s)
	testing.expect(t, visible && label == "Maximize", "a neighbour shows at once")

	testing.expect(t, ui.tooltip_hover(&s, "", {70, 10}, 1, after(left, 20 * time.Millisecond), false))
	late := after(left, 20 * time.Millisecond + ui.TOOLTIP_GRACE + time.Millisecond)
	testing.expect(t, ui.tooltip_hover(&s, "Close", {90, 10}, 1, late, false))
	_, visible = ui.tooltip_shown(&s)
	testing.expect(t, !visible, "after the grace the delay applies again")
	testing.expect_value(t, ui.tooltip_current(&s), "Close")
}

// A pressed button cancels the tooltip, and the label is kept as a copy cut at a character boundary.
@(test)
tooltip_copies_its_label_and_a_press_cancels_it :: proc(t: ^testing.T) {
	s: ui.Tooltip_State
	text: [ui.TOOLTIP_LIMIT + 1]u8
	for &b in text {b = 'a'}
	text[ui.TOOLTIP_LIMIT - 1], text[ui.TOOLTIP_LIMIT] = 0xC3, 0xA9 // "é" across the limit
	start := time.tick_now()
	_ = ui.tooltip_hover(&s, string(text[:]), {0, 0}, 1, start, false)
	text[0] = 'b'
	current := ui.tooltip_current(&s)
	testing.expect_value(t, len(current), ui.TOOLTIP_LIMIT - 1)
	testing.expect_value(t, current[0], 'a')
	testing.expect(t, ui.tooltip_hover(&s, "Minimize", {0, 0}, 1, start, true))
	testing.expect(t, s.tooltip == nil)
	testing.expect(t, !ui.tooltip_cancel(&s), "nothing left to cancel")
}

@(private = "file")
Bar :: enum u8 {None, Rail, Page}

// A held track press repeats after SCROLLBAR_REPEAT_DELAY and then every SCROLLBAR_REPEAT_INTERVAL from
// when it paged, toward the pointer's latest position; the zero hold holds nothing.
@(test)
scroll_hold_repeats_toward_the_pointer :: proc(t: ^testing.T) {
	h: ui.Scroll_Hold(Bar)
	_, held := ui.scroll_hold_deadline(h)
	testing.expect(t, !held)
	start := time.tick_now()
	ui.scroll_hold_begin(&h, Bar.Page, {5, 100}, .After, start)
	due, waiting := ui.scroll_hold_deadline(h)
	testing.expect(t, waiting && due == after(start, ui.SCROLLBAR_REPEAT_DELAY))
	testing.expect(t, !ui.scroll_hold_due(&h, after(due, -time.Millisecond)))
	ui.scroll_hold_move(&h, {5, 300})
	stalled := after(due, time.Second)
	testing.expect(t, ui.scroll_hold_due(&h, stalled))
	testing.expect_value(t, h.pointer, [2]f32{5, 300})
	next, _ := ui.scroll_hold_deadline(h)
	testing.expect_value(t, next, after(stalled, ui.SCROLLBAR_REPEAT_INTERVAL))
	testing.expect(t, !ui.scroll_hold_due(&h, stalled), "a stalled loop pages once")
	h = {}
	ui.scroll_hold_move(&h, {1, 1})
	testing.expect_value(t, h.pointer, [2]f32{})
}

// Past an edge the drag scrolls every EDGE_SCROLL_INTERVAL; back inside it stops.
@(test)
edge_scroll_steps_while_outside :: proc(t: ^testing.T) {
	e: ui.Edge_Scroll
	start := time.tick_now()
	testing.expect(t, !ui.edge_scroll_follow(&e, false, start))
	testing.expect(t, ui.edge_scroll_follow(&e, true, start))
	testing.expect(t, !ui.edge_scroll_follow(&e, true, after(start, 10 * time.Millisecond)), "still outside")
	due, scrolling := ui.edge_scroll_deadline(e)
	testing.expect(t, scrolling && due == after(start, ui.EDGE_SCROLL_INTERVAL))
	testing.expect(t, !ui.edge_scroll_due(&e, after(due, -time.Millisecond)))
	testing.expect(t, ui.edge_scroll_due(&e, due))
	testing.expect(t, !ui.edge_scroll_due(&e, due), "once per interval")
	testing.expect(t, ui.edge_scroll_follow(&e, false, due))
	_, scrolling = ui.edge_scroll_deadline(e)
	testing.expect(t, !scrolling)
}
