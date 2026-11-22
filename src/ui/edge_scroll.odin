package ui

import "core:time"

// How often a drag held past a scrolling area's edge scrolls it a step.
EDGE_SCROLL_INTERVAL :: 30 * time.Millisecond

// A selecting drag held past the top or bottom edge of what it selects in scrolls that on a timer, so a
// still pointer keeps selecting. The owner says when the pointer is past an edge and what a step scrolls;
// this keeps when the next step is due. The zero value is not scrolling.
Edge_Scroll :: struct {
	due: Maybe(time.Tick),
}

// The pointer moved, past an edge when `outside`: scrolling starts an interval from `now`, or stops. True
// when it started or stopped.
edge_scroll_follow :: proc(e: ^Edge_Scroll, outside: bool, now: time.Tick) -> bool {
	if !outside {
		stopped := e.due != nil
		e.due = nil
		return stopped
	}
	if e.due != nil {return false}
	e.due = time.tick_add(now, EDGE_SCROLL_INTERVAL)
	return true
}

edge_scroll_stop :: proc(e: ^Edge_Scroll) {
	e.due = nil
}

edge_scroll_deadline :: proc(e: Edge_Scroll) -> (time.Tick, bool) {
	return e.due.?
}

// True when a step is due, which the owner then scrolls. The next is an interval after `now`, so a stalled
// loop steps once on waking rather than catching up.
edge_scroll_due :: proc(e: ^Edge_Scroll, now: time.Tick) -> bool {
	due, scrolling := e.due.?
	if !scrolling || time.tick_diff(due, now) < 0 {return false}
	e.due = time.tick_add(now, EDGE_SCROLL_INTERVAL)
	return true
}
