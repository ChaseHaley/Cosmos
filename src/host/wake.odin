package host

import "base:runtime"
import "cosmos:platform"
import "core:log"
import "core:sync"

// Wakes an app's UI loop from any thread. `procedure` runs on the waking thread without a context, so it
// must only signal: set a flag, post an event.
Waker :: struct {
	procedure: proc "contextless" (data: rawptr),
	data:      rawptr,
}

// Runs `w`; a zero Waker does nothing, as in tests without a loop.
wake :: proc "contextless" (w: Waker) {
	if w.procedure != nil {w.procedure(w.data)}
}

// The waker for `p`'s loop: its next wait returns with a wake event.
waker_platform :: proc(p: ^platform.Platform) -> Waker {
	return {platform_wake, p}
}

@(private)
platform_wake :: proc "contextless" (data: rawptr) {
	context = runtime.default_context()
	if platform.wake((^platform.Platform)(data)) != .None {log.error("waking the main loop failed")}
}

// News from a worker that the UI thread reads on its next pass: the worker raises it and wakes the
// loop, and the UI thread takes it, so any number of raises between passes cost one pass.
Signal :: struct {
	raised: bool,
	waker:  Waker,
}

signal_raise :: proc "contextless" (s: ^Signal) {
	sync.atomic_store(&s.raised, true)
	wake(s.waker)
}

// Whether the signal was raised since the last take, clearing it.
signal_take :: proc "contextless" (s: ^Signal) -> bool {
	return sync.atomic_exchange(&s.raised, false)
}

// Whether the signal is raised, leaving it raised.
signal_raised :: proc "contextless" (s: ^Signal) -> bool {
	return sync.atomic_load(&s.raised)
}

// A Waker that raises `s`, for a worker that takes a waker rather than a signal.
signal_waker :: proc(s: ^Signal) -> Waker {
	return {proc "contextless" (data: rawptr) {signal_raise((^Signal)(data))}, s}
}
