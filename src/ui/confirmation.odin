package ui

import "base:intrinsics"

// The question a window asks before a change it cannot undo, about `subject`, which holds what its answer
// and its text need. A window asks at most one, held as a Maybe: nil asks nothing; otherwise the dialog's
// presence is the phase, Asking while it opens or shows (presence_is_open) and Closing while an answered or
// dismissed question fades out. A closing question keeps its subject, so it draws unchanged until the fade
// settles; then confirmation_advance says so, and the owner releases the subject and clears the question.
Confirmation :: struct($Subject: typeid) {
	dialog:  Confirm,
	subject: Subject,
}

// The question shown, asking or closing; nil when it asks nothing. `Q` is a Confirmation(Subject); every
// procedure here takes the window's Maybe of one.
confirmation_shown :: proc(
	q: ^Maybe($Q),
) -> ^Q where intrinsics.type_is_specialization_of(Q, Confirmation) {
	c, ok := &q.?
	return ok ? c : nil
}

// The dialog of the question that is asking, which has the window's input; nil otherwise.
confirmation_current :: proc(q: ^Maybe($Q)) -> ^Confirm {
	c := confirmation_shown(q)
	return c != nil && presence_is_open(c.dialog.presence) ? &c.dialog : nil
}

// The subject of the question shown, asking or closing, when it is a T: one variant of the subject union.
confirmation_subject :: proc(q: ^Maybe($Q), $T: typeid) -> ^T {
	c := confirmation_shown(q)
	if c == nil {return nil}
	subject, _ := &c.subject.(T)
	return subject
}

// The subject of the question that is asking, when it is a T.
confirmation_asking :: proc(q: ^Maybe($Q), $T: typeid) -> ^T {
	if confirmation_current(q) == nil {return nil}
	return confirmation_subject(q, T)
}

// Asks about `subject`, presenting it as stated. The owner has released any question shown before.
confirmation_ask :: proc(
	q: ^Maybe($Q),
	subject: $S,
	extended := false,
	focus := Confirm_Button.Accept,
	show_option := false,
) where intrinsics.type_is_specialization_of(Q, Confirmation) {
	c: Q
	c.subject = subject
	confirm_open(&c.dialog, extended, focus, show_option)
	q^ = c
}

// Answers the asking question: the dialog starts closing with its subject intact, and this returns the
// question for the owner to act on its subject. nil when nothing is asking.
confirmation_answer :: proc(q: ^Maybe($Q)) -> ^Q {
	if confirmation_current(q) == nil {return nil}
	c := confirmation_shown(q)
	confirm_close(&c.dialog)
	return c
}

// Capture loss cancels a press without dismissing the question or allowing a later release to fire.
confirmation_release :: proc(q: ^Maybe($Q)) {
	c := confirmation_shown(q)
	if c == nil {return}
	armed_cancel(&c.dialog.armed)
	c.dialog.hover = .None
}

// The question is fading in or out, or its buttons' hover is moving.
confirmation_active :: proc(q: ^Maybe($Q)) -> bool {
	c := confirmation_shown(q)
	return c != nil && (presence_active(c.dialog.presence) || control_active(c.dialog.hover_motion))
}

// Moves the fade and the buttons' hover a frame on. `settled` is true once a closing question has faded
// out: the owner releases its subject and sets the question to nil.
confirmation_advance :: proc(q: ^Maybe($Q), animations: bool, frame: Frame_Time) -> (
	changed: bool,
	settled: bool,
) {
	c := confirmation_shown(q)
	if c == nil {return false, false}
	changed, settled = presence_advance(&c.dialog.presence, animations, frame)
	hovered := c.dialog.hover != .None
	changed = control_update(&c.dialog.hover_motion, hovered, false, animations, frame) || changed
	return changed, settled
}
