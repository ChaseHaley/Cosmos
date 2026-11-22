package host

import "core:time"

// A caret's blink; nil is a steady caret. On shows the caret while `visible` and flips it when
// `deadline` passes, `interval` later each time. The procs in this file are the only writers.
Blink :: union {
	Blink_On,
}

Blink_On :: struct {
	visible:  bool,
	deadline: time.Tick,
	interval: time.Duration,
}

// Whether the caret is in its shown phase; a steady caret always is.
blink_visible :: proc(b: Blink) -> bool {
	on, blinking := b.(Blink_On)
	return !blinking || on.visible
}

// When the caret next flips, if it blinks.
blink_deadline :: proc(b: Blink) -> (time.Tick, bool) {
	on, blinking := b.(Blink_On)
	return on.deadline, blinking
}

// The frame just built found whether the caret blinks; a change starts or stops the cycle, and
// `interval` is how long each phase lasts. A running cycle keeps its phase and takes the new interval.
blink_observe :: proc(b: ^Blink, blinking: bool, interval: time.Duration, now: time.Tick) {
	if !blinking {
		b^ = nil
		return
	}
	if on, running := &b.(Blink_On); running {
		on.interval = interval
		return
	}
	b^ = Blink_On{true, time.tick_add(now, interval), interval}
}

// Flips the caret once its deadline has passed; `changed` when it did, so the caret needs drawing.
blink_tick :: proc(b: ^Blink, now: time.Tick) -> (changed: bool) {
	on, blinking := &b.(Blink_On)
	if !blinking || time.tick_diff(on.deadline, now) < 0 {return false}
	on.visible = !on.visible
	on.deadline = time.tick_add(now, on.interval)
	return true
}

// Restarts the cycle with the caret shown, so typing never hides the caret.
blink_reset :: proc(b: ^Blink, now: time.Tick) {
	if on, blinking := &b.(Blink_On); blinking {
		on.visible, on.deadline = true, time.tick_add(now, on.interval)
	}
}
