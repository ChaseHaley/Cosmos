package host

import "cosmos:platform"
import "cosmos:render"
import "core:log"
import "core:time"

// The most swap chains one wait watches; platform.wait_events takes 63 handles, one of them the wake.
FRAME_WAITS_MAX :: 32

// The windows that want a frame and how the loop learns it may draw them: a window with a swap chain
// draws when the swap chain signals room for its next frame, so frames follow the display's refresh and
// each window keeps its own display's pace.
Frame_Waits :: struct {
	handles:  [FRAME_WAITS_MAX]rawptr,
	surfaces: [FRAME_WAITS_MAX]^render.Surface,
	count:    int,
	// A window can draw at once: it has no surface yet, which its next frame makes.
	ready:    bool,
	// A window wants frames that its swap chain cannot wake the loop for: it cannot present but still has
	// motion to finish, it holds a frame it failed to draw, or no wait slot is left. The loop retries on
	// the assumed refresh.
	unpaced:  bool,
}

// Adds a window to the wait. `drawable` is false while it cannot present, as when minimized; `wants`
// says it has something to draw, and `animating` that it has motion to finish.
frame_waits_add :: proc(waits: ^Frame_Waits, surface: Surface, drawable, wants, animating: bool) {
	if !drawable {
		waits.unpaced ||= animating
		return
	}
	if !wants && !animating {return}
	switch s in surface {
	case ^render.Surface:
		handle := render.frame_waitable(s)
		if handle == nil || waits.count == FRAME_WAITS_MAX {
			waits.unpaced = true
			return
		}
		waits.handles[waits.count], waits.surfaces[waits.count] = handle, s
		waits.count += 1
	case Surface_Failed:
		waits.unpaced ||= animating
	case nil:
		waits.ready = true
	}
}

// How long the loop may sleep: not at all while a window can draw at once, the assumed refresh while
// one is unpaced, and otherwise until the earliest timer `deadline`, if `found`.
frame_wait_ms :: proc(waits: Frame_Waits, deadline: time.Tick, found: bool, now: time.Tick) -> u32 {
	if waits.ready {return 0}
	if waits.unpaced {return u32(time.duration_milliseconds(render.FRAME_PERIOD_DEFAULT))}
	return wait_ms(deadline, found, now)
}

// Sleeps up to `timeout_ms` for an OS event, a waker or a waited swap chain's room for its next frame;
// a swap chain that signaled is acquired, so its window draws without waiting again.
frame_wait :: proc(p: ^platform.Platform, waits: ^Frame_Waits, timeout_ms: u32) -> platform.Error {
	signaled, err := platform.wait_events(p, timeout_ms, waits.handles[:waits.count])
	if signaled >= 0 && signaled < waits.count {render.frame_signaled(waits.surfaces[signaled])}
	return err
}

// Starts a window's frame: waits up to `timeout_ms` for room in the swap chain, then predicts when the
// frame will show, which is the time the frame's motion samples. False when the swap chain has no room yet.
frame_begin :: proc(surface: ^render.Surface, now: time.Tick, timeout_ms: u32) -> (
	frame: render.Frame_Time,
	ready: bool,
) {
	acquired, err := render.frame_acquire(surface, timeout_ms)
	if err == .Wait_Failed {log.error("waiting for the swap chain failed")}
	if !acquired {return {}, false}
	return render.frame_predict(surface, now), true
}

// Builds a draw list with `build`, which receives `ctx`, and builds it again when an atlas reset stopped
// it. False when the build failed: only a completed draw list may be presented, so the window keeps
// wanting a frame and a later build can recover.
frame_build :: proc(
	list: ^render.Draw_List,
	device: ^render.Device,
	ctx: $Ctx,
	build: proc(ctx: Ctx),
) -> bool {
	frame := render.frame_build_begin(list, device)
	for {
		build(ctx)
		switch render.frame_build_finish(&frame) {
		case .Ready:
			return true
		case .Retry:
		case .Failed:
			return false
		}
	}
}

// Ends a window's frame after its present: a frame that showed teaches the swap chain's clock, and
// `moved` says it carried motion. A failed present leaves the clock as it was.
frame_end :: proc(surface: ^render.Surface, frame: render.Frame_Time, presented, moved: bool) {
	if presented {render.frame_presented(surface, frame, moved)}
}
