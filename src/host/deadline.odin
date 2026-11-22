package host

import "core:time"

// The longest the loop sleeps without a signal, so a clock change or a lost wake costs at most this.
WAIT_LIMIT_MS :: 60_000

// The earlier of a deadline found so far, if any, and `next`. Folds the deadlines of an app's timers
// into one: `found` is false until the first.
earliest :: proc(current: time.Tick, found: bool, next: time.Tick) -> (time.Tick, bool) {
	if found && time.tick_diff(next, current) <= 0 {return current, true}
	return next, true
}

// How long the loop may sleep until `deadline`, in whole milliseconds rounded up, capped at
// WAIT_LIMIT_MS; forever when nothing is `found`.
wait_ms :: proc(deadline: time.Tick, found: bool, now: time.Tick) -> u32 {
	if !found {return max(u32)}
	remaining := time.tick_diff(now, deadline)
	return u32(clamp(time.duration_milliseconds(remaining) + 1, 0, WAIT_LIMIT_MS))
}
