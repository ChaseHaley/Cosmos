package host

import "cosmos:input"

// What a drag a surface holds did with a move.
Pointer_Held :: enum u8 {
	// No drag of this surface is held, or it leaves this move to the surfaces.
	Free,
	// The drag followed the move, which ends there.
	Taken,
	// The move ended a drag whose release was missed. What lies under the pointer may have changed with it,
	// so routing resolves the target again.
	Ended,
}

// Everything a surface tells the pointer router: its handlers and its policy. An app lists the surfaces
// that can own the pointer in an enum `Target`, topmost first, and keeps one of these per target. The
// order is the precedence: hover, cursor and press all resolve through pointer_target, so the surface that
// shows a hover is the one a press reaches, and the surfaces beneath it see the pointer leave. Every
// handler receives the app's `App` and the `Window` the pointer is in; each but `claims` may be nil.
Pointer_Surface :: struct($App, $Window, $Target: typeid) {
	// Whether the point lies on the surface while it is showing.
	claims:       proc(app: ^App, w: ^Window, x, y: f32) -> bool,
	// Runs for every surface on every move. The owner updates its hover and sets the cursor; every other
	// surface clears its own hover, cheaply when there is none.
	hover:        proc(app: ^App, w: ^Window, owner: Target, e: input.Mouse_Move_Event),
	// A press the surface owns. A modal surface also receives every release while it is open.
	press:        proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event),
	// The release of a press the surface owned, wherever it lands; false passes it on to the app's shared
	// completion. A release of a press the surface swallowed ends there either way.
	release:      proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool,
	// Capture loss: the surface drops its hover, armed control and drag, whether or not it holds a button.
	cancel:       proc(app: ^App, w: ^Window),
	// The pointer left the window: the surface drops its hover, as a move another surface owns does.
	leave:        proc(app: ^App, w: ^Window),
	// A drag the surface holds follows every move before hover runs; `under` is the surface under the
	// pointer. Only one drag is held at a time, since each starts with a Left press.
	held:         proc(app: ^App, w: ^Window, under: Target, e: input.Mouse_Move_Event) -> Pointer_Held,
	// Takes the whole window while it shows: every press, every release that began elsewhere, and the
	// moves of held presses and of drags that have not started.
	modal:        bool,
	// A press here keeps the pointer with this surface until its release, whatever buttons a move reports.
	holds:        bool,
	// Something the app draws over the surface, such as a floating pane, hides it where it covers.
	under_covers: bool,
}

// The topmost surface whose area holds the point, leaving out the `absent` ones and, where `covers` says
// something covers the point, those under covers; `fallback` when none claims it.
pointer_target :: proc(
	surfaces: ^[$Target]Pointer_Surface($App, $Window, Target),
	app: ^App,
	w: ^Window,
	x, y: f32,
	absent: bit_set[Target],
	covers: proc(w: ^Window, x, y: f32) -> bool,
	fallback: Target,
) -> Target {
	for target in Target {
		if target in absent {continue}
		surface := &surfaces[target]
		if surface.under_covers && covers != nil && covers(w, x, y) {continue}
		if surface.claims(app, w, x, y) {return target}
	}
	return fallback
}

// Lets every surface see the move: the owner hovers and sets the cursor, the rest clear their hover.
pointer_move :: proc(
	surfaces: ^[$Target]Pointer_Surface($App, $Window, Target),
	app: ^App,
	w: ^Window,
	owner: Target,
	e: input.Mouse_Move_Event,
) {
	for surface in surfaces {
		if surface.hover != nil {surface.hover(app, w, owner, e)}
	}
}

// The pointer left the window: every surface drops its hover through its own leave.
pointer_leave :: proc(surfaces: ^[$Target]Pointer_Surface($App, $Window, Target), app: ^App, w: ^Window) {
	for surface in surfaces {
		if surface.leave != nil {surface.leave(app, w)}
	}
}

// Capture loss: every surface drops its pointer state through its own cancel.
pointer_cancel :: proc(surfaces: ^[$Target]Pointer_Surface($App, $Window, Target), app: ^App, w: ^Window) {
	for surface in surfaces {
		if surface.cancel != nil {surface.cancel(app, w)}
	}
}

// The held drag, if any, follows the move.
pointer_held :: proc(
	surfaces: ^[$Target]Pointer_Surface($App, $Window, Target),
	app: ^App,
	w: ^Window,
	under: Target,
	e: input.Mouse_Move_Event,
) -> Pointer_Held {
	for surface in surfaces {
		if surface.held == nil {continue}
		if held := surface.held(app, w, under, e); held != .Free {return held}
	}
	return .Free
}

pointer_press :: proc(
	surfaces: ^[$Target]Pointer_Surface($App, $Window, Target),
	app: ^App,
	w: ^Window,
	owner: Target,
	e: input.Mouse_Button_Event,
) {
	if press := surfaces[owner].press; press != nil {press(app, w, e)}
}

// The release reached the surface that owned its press; false when it declined, or has no release.
pointer_release :: proc(
	surfaces: ^[$Target]Pointer_Surface($App, $Window, Target),
	app: ^App,
	w: ^Window,
	owner: Target,
	e: input.Mouse_Button_Event,
) -> bool {
	release := surfaces[owner].release
	return release != nil && release(app, w, e)
}
