package ui_test

import "cosmos:ui"
import "core:testing"
import "core:time"

@(private = "file")
Close :: struct {
	tabs: int,
}

@(private = "file")
Restart :: struct {}

@(private = "file")
Subject :: union {
	Close,
	Restart,
}

@(private = "file")
frame_at :: proc(start: time.Tick, frame: int) -> time.Tick {
	return time.tick_add(start, time.Duration(frame) * TEST_FRAME_PERIOD)
}

// An answered question stops taking input at once but keeps its subject while it fades out; the fade's
// end tells the owner to release it. Answering gives focus back to the control that had it before.
@(test)
confirmation_keeps_its_subject_until_the_fade_settles :: proc(t: ^testing.T) {
	q: Maybe(ui.Confirmation(Subject))
	focus: ui.Focus
	ui.focus_init(&focus)
	defer ui.focus_destroy(&focus)
	ui.focus_set(&focus, 7, false)
	testing.expect(t, ui.confirmation_answer(&q, &focus) == nil, "nothing to answer")
	ui.confirmation_ask(&q, &focus, 100, Subject(Close{tabs = 3}))
	testing.expect_value(t, focus.focused, ui.Focus_Id(102))
	testing.expect(t, ui.confirmation_current(&q) != nil)
	testing.expect(t, ui.confirmation_asking(&q, Restart) == nil)
	asking := ui.confirmation_asking(&q, Close)
	if !testing.expect(t, asking != nil) {return}
	testing.expect_value(t, asking.tabs, 3)

	start := time.tick_now()
	for i in 0 ..< 60 {_, _ = ui.confirmation_advance(&q, true, test_frame(frame_at(start, i)))}
	testing.expect(t, !ui.confirmation_active(&q), "open and still")

	answered := ui.confirmation_answer(&q, &focus)
	testing.expect_value(t, focus.focused, ui.Focus_Id(7))
	if !testing.expect(t, answered != nil) {return}
	testing.expect(t, ui.confirmation_current(&q) == nil, "closing takes no input")
	testing.expect(t, ui.confirmation_asking(&q, Close) == nil)
	closing := ui.confirmation_subject(&q, Close)
	testing.expect(t, closing != nil && closing.tabs == 3, "the subject stays while it fades")
	testing.expect(t, ui.confirmation_answer(&q, &focus) == nil, "answered once")

	settled := false
	for i in 60 ..< 120 {
		_, settled = ui.confirmation_advance(&q, true, test_frame(frame_at(start, i)))
		if settled {break}
	}
	testing.expect(t, settled, "the fade ends")
	testing.expect(t, ui.confirmation_shown(&q) != nil, "the owner releases the subject")
	q = nil
	changed, done := ui.confirmation_advance(&q, true, test_frame(start))
	testing.expect(t, !changed && !done)
}

// Without animations the question closes on the next advance.
@(test)
confirmation_closes_at_once_without_animations :: proc(t: ^testing.T) {
	q: Maybe(ui.Confirmation(Subject))
	focus: ui.Focus
	ui.focus_init(&focus)
	defer ui.focus_destroy(&focus)
	ui.confirmation_ask(&q, &focus, 100, Subject(Restart{}))
	_ = ui.confirmation_answer(&q, &focus)
	_, settled := ui.confirmation_advance(&q, false, test_frame(time.tick_now()))
	testing.expect(t, settled)
}
