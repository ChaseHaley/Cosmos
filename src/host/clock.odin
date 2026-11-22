package host

import "cosmos:platform"
import "core:time"

// An app's one source of time. Everything the UI thread times, animates or shows as an age reads it, so
// a build that drives time itself replaces these procs alone. Frame statistics, work budgets and
// cross-thread timeouts keep the system clock: they measure real work and change no frame's content.
when platform.HEADLESS {
	// Follows the system clock until a test sets `stepped`; from then on the clock reads `now` and
	// `wall`, and time moves only when the test advances them.
	Clock :: struct {
		stepped: bool,
		now:     time.Tick,
		wall:    time.Time,
	}

	clock_now :: proc(c: ^Clock) -> time.Tick {
		return c.stepped ? c.now : time.tick_now()
	}

	// The time of day, for ages shown on screen.
	clock_wall :: proc(c: ^Clock) -> time.Time {
		return c.stepped ? c.wall : time.now()
	}
} else {
	Clock :: struct {}

	clock_now :: proc(c: ^Clock) -> time.Tick {
		return time.tick_now()
	}

	// The time of day, for ages shown on screen.
	clock_wall :: proc(c: ^Clock) -> time.Time {
		return time.now()
	}
}
