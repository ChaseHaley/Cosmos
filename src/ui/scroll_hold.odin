package ui

import "base:intrinsics"
import "core:time"

// A Left press held on a scrollbar's track, as Windows repeats it: the press pages once at once toward the
// pointer (the owner's press does that), and while the button stays down the owner pages again after
// SCROLLBAR_REPEAT_DELAY and then every SCROLLBAR_REPEAT_INTERVAL, toward wherever the pointer is then,
// until the thumb reaches it. Leaving the track pauses the paging and coming back resumes it; the release
// ends it. `bar` names the owner's scrollbar; its zero value is none, so the zero hold holds nothing.
Scroll_Hold :: struct($Bar: typeid) where intrinsics.type_is_comparable(Bar) {
	bar:     Bar,
	// The pointer as the last move left it; each repeat pages toward it.
	pointer: [2]f32,
	// The side of the thumb the press began on; the repeat pages only from there.
	side:    Scroll_Side,
	// When the next page is due.
	due:     time.Tick,
}

// Holds the track press at `point` that has just paged once on `bar`.
scroll_hold_begin :: proc(h: ^Scroll_Hold($Bar), bar: Bar, point: [2]f32, side: Scroll_Side, now: time.Tick) {
	h^ = {
		bar     = bar,
		pointer = point,
		side    = side,
		due     = time.tick_add(now, SCROLLBAR_REPEAT_DELAY),
	}
}

scroll_hold_held :: proc(h: Scroll_Hold($Bar)) -> bool {
	none: Bar
	return h.bar != none
}

// The pointer moved: the next page aims at it.
scroll_hold_move :: proc(h: ^Scroll_Hold($Bar), point: [2]f32) {
	if scroll_hold_held(h^) {h.pointer = point}
}

scroll_hold_deadline :: proc(h: Scroll_Hold($Bar)) -> (time.Tick, bool) {
	return h.due, scroll_hold_held(h)
}

// True when the next page is due, which the owner then pages toward `pointer` from `side`. The page after
// is a repeat interval after this one, not after the due time, so a stalled loop pages once on waking
// rather than catching up.
scroll_hold_due :: proc(h: ^Scroll_Hold($Bar), now: time.Tick) -> bool {
	if !scroll_hold_held(h^) || time.tick_diff(h.due, now) < 0 {return false}
	h.due = time.tick_add(now, SCROLLBAR_REPEAT_INTERVAL)
	return true
}
