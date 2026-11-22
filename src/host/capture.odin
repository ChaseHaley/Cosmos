package host

import "cosmos:input"

// What each mouse button is doing between its press and its release; nil is a free button. Every press
// records who holds it before any handler sees it, so a release and the moves before it go to whoever the
// press recorded, never to fresh hit testing. `Owner` names who holds a press, `By` who consumed one and
// `To` where one was forwarded, such as the program in a terminal pane.
Captures :: struct($Owner, $By, $To: typeid) {
	buttons: [input.Mouse_Button]Capture(Owner, By, To),
}

Capture :: union($Owner, $By, $To: typeid) {
	Capture_Held(Owner),
	Capture_Swallowed(By),
	Capture_Forwarded(To),
	Capture_Cancelled,
}

// Pressed on `owner`, which receives the release; a release it declines reaches the app's shared
// completion.
Capture_Held :: struct($Owner: typeid) {
	owner: Owner,
}

// Consumed by `by`: neither half reaches content, and the release goes to `by` alone.
Capture_Swallowed :: struct($By: typeid) {
	by: By,
}

// Sent on to `to`, which also receives the release, wherever it lands.
Capture_Forwarded :: struct($To: typeid) {
	to: To,
}

// The pointer was taken away while the button was down: its moves and its release reach nothing.
Capture_Cancelled :: struct {}

// A press of `button` that `owner` holds.
capture_press :: proc(c: ^Captures($Owner, $By, $To), button: input.Mouse_Button, owner: Owner) {
	c.buttons[button] = Capture_Held(Owner){owner}
}

// The handler holding `button` consumes it. A press the handler already cancelled stays cancelled.
capture_swallow :: proc(c: ^Captures($Owner, $By, $To), button: input.Mouse_Button, by: By) {
	if _, held := c.buttons[button].(Capture_Held(Owner)); held {
		c.buttons[button] = Capture_Swallowed(By){by}
	}
}

// The handler holding `button` sends it on to `to`.
capture_forward :: proc(c: ^Captures($Owner, $By, $To), button: input.Mouse_Button, to: To) {
	if _, held := c.buttons[button].(Capture_Held(Owner)); held {
		c.buttons[button] = Capture_Forwarded(To){to}
	}
}

// The handler holding `button` passes it on to `owner`, which then holds it.
capture_hand_off :: proc(c: ^Captures($Owner, $By, $To), button: input.Mouse_Button, owner: Owner) {
	if _, held := c.buttons[button].(Capture_Held(Owner)); held {
		c.buttons[button] = Capture_Held(Owner){owner}
	}
}

// The held button stops reaching anything until it is released.
capture_cancel :: proc(c: ^Captures($Owner, $By, $To), button: input.Mouse_Button) {
	if c.buttons[button] != nil {c.buttons[button] = Capture_Cancelled{}}
}

// The release of `button`: what its press recorded, leaving the button free.
capture_release :: proc(
	c: ^Captures($Owner, $By, $To),
	button: input.Mouse_Button,
) -> Capture(Owner, By, To) {
	capture := c.buttons[button]
	c.buttons[button] = nil
	return capture
}

// The buttons whose capture is a T, such as Capture_Swallowed(By).
capture_buttons :: proc(c: ^Captures($Owner, $By, $To), $T: typeid) -> (buttons: input.Mouse_Buttons) {
	for capture, button in c.buttons {
		if _, ok := capture.(T); ok {buttons += {button}}
	}
	return
}
