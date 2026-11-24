package ui_test

import "cosmos:input"
import "core:testing"
import "cosmos:ui"

@(private="file")
press :: proc(key: input.Key_Event) -> input.Key_Event {
	e := key
	e.pressed = true
	return e
}

// The window's own control, which has focus before the dialog opens.
@(private="file")
WINDOW_CONTROL :: ui.Focus_Id(1)

@(private="file")
DIALOG :: ui.Focus_Id(10)

// One built frame: the window's control, then the dialog over it.
@(private="file")
frame :: proc(c: ^ui.Confirm, f: ^ui.Focus) {
	ui.focus_frame_begin(f)
	ui.focus_add(f, WINDOW_CONTROL)
	ui.confirm_focus_add(c, f)
	ui.focus_frame_end(f)
}

@(test)
confirm_keys_choose_cancel_or_accept :: proc(t: ^testing.T) {
	c: ui.Confirm
	f: ui.Focus
	ui.focus_init(&f)
	defer ui.focus_destroy(&f)
	ui.focus_set(&f, WINDOW_CONTROL, false)
	ui.confirm_open(&c, &f, DIALOG)
	frame(&c, &f)
	testing.expect_value(t, ui.confirm_focused(c, f), ui.Confirm_Button.Accept)
	testing.expect(t, ui.focus_visible(f, f.focused), "the first focus shows which button Enter answers with")
	testing.expect_value(t, ui.confirm_key(&c, &f, press({key = .Enter}), ""), ui.Confirm_Outcome.Accept)
	testing.expect_value(t, ui.confirm_key(&c, &f, press({key = .Escape}), ""), ui.Confirm_Outcome.Cancel)
	testing.expect_value(t, ui.confirm_key(&c, &f, {key = .Enter}, ""), ui.Confirm_Outcome.None)
	testing.expect_value(t, ui.confirm_key(&c, &f, press({key = .Tab}), ""), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_focused(c, f), ui.Confirm_Button.Cancel)
	testing.expect_value(t, ui.confirm_key(&c, &f, press({key = .Space}), ""), ui.Confirm_Outcome.Cancel)
	testing.expect_value(t, ui.confirm_key(&c, &f, press({key = .Arrow_Right}), ""), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_focused(c, f), ui.Confirm_Button.Accept)
	testing.expect_value(t, ui.confirm_key(&c, &f, press({key = .A}), ""), ui.Confirm_Outcome.None)
	// Ctrl+Tab belongs to the app, so it neither moves the dialog's focus nor leaves the dialog.
	ctrl_tab := press({key = .Tab, modifiers = {.Control}})
	testing.expect_value(t, ui.confirm_key(&c, &f, ctrl_tab, ""), ui.Confirm_Outcome.None)
	testing.expect_value(t, ui.confirm_focused(c, f), ui.Confirm_Button.Accept)
	ui.confirm_key(&c, &f, press({key = .Tab}), "")
	ui.confirm_open(&c, &f, DIALOG)
	testing.expect_value(t, ui.confirm_focused(c, f), ui.Confirm_Button.Accept)
	// Asked again while it asks, the dialog still gives focus back to the window's control.
	ui.confirm_close(&c, &f)
	testing.expect_value(t, f.focused, WINDOW_CONTROL)
	frame(&c, &f)
	testing.expect_value(t, f.focused, WINDOW_CONTROL)
}

// A dialog opens with the presentation its question states, so nothing a previous question set survives.
@(test)
confirm_open_takes_its_presentation_and_unchecks_the_option :: proc(t: ^testing.T) {
	c: ui.Confirm
	f: ui.Focus
	ui.focus_init(&f)
	defer ui.focus_destroy(&f)
	option :: "Don't ask again"
	alt_d := press({key = .D, modifiers = {.Alt}})
	ui.confirm_open(&c, &f, DIALOG, show_option = true)
	frame(&c, &f)
	testing.expect_value(t, ui.confirm_key(&c, &f, alt_d, option), ui.Confirm_Outcome.Changed)
	testing.expect(t, c.option && c.show_option && !c.extended)
	testing.expect_value(t, ui.confirm_focused(c, f), ui.Confirm_Button.Option)
	testing.expect_value(t, ui.confirm_key(&c, &f, press({key = .Tab}), option), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_focused(c, f), ui.Confirm_Button.Cancel)
	testing.expect_value(t, ui.confirm_key(&c, &f, press({key = .Arrow_Up}), option), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_focused(c, f), ui.Confirm_Button.Option)
	testing.expect_value(t, ui.confirm_key(&c, &f, press({key = .Space}), option), ui.Confirm_Outcome.Changed)
	testing.expect(t, !c.option, "Space toggles the focused option")
	// The accelerator is the label's first letter, not a fixed chord.
	testing.expect_value(t, ui.confirm_key(&c, &f, alt_d, "Keep both"), ui.Confirm_Outcome.None)
	testing.expect_value(t, ui.confirm_key(&c, &f, press({key = .K, modifiers = {.Alt}}), "Keep both"),
		ui.Confirm_Outcome.Changed)
	ui.confirm_open(&c, &f, DIALOG, extended = true, focus = .Cancel)
	frame(&c, &f)
	testing.expect(t, !c.option && !c.show_option && c.extended)
	testing.expect_value(t, ui.confirm_focused(c, f), ui.Confirm_Button.Cancel)
	testing.expect_value(t, ui.confirm_key(&c, &f, press({key = .Tab}), option), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_focused(c, f), ui.Confirm_Button.Accept)
	testing.expect_value(t, ui.confirm_key(&c, &f, press({key = .Tab}), option), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_focused(c, f), ui.Confirm_Button.Cancel)
	testing.expect_value(t, ui.confirm_key(&c, &f, alt_d, option), ui.Confirm_Outcome.None)
}

// A press focuses its button without the ring, which comes back with the keyboard.
@(test)
confirm_pointer_needs_press_and_release_on_one_button :: proc(t: ^testing.T) {
	c: ui.Confirm
	f: ui.Focus
	ui.focus_init(&f)
	defer ui.focus_destroy(&f)
	ui.confirm_open(&c, &f, DIALOG)
	frame(&c, &f)
	l := ui.confirm_layout(1000, 700, 1)
	accept := [2]f32{l.accept.x + l.accept.width / 2, l.accept.y + l.accept.height / 2}
	cancel := [2]f32{l.cancel.x + l.cancel.width / 2, l.cancel.y + l.cancel.height / 2}
	inside := [2]f32{l.panel.x + 10, l.panel.y + 10}
	testing.expect_value(t, ui.confirm_mouse(&c, &f, l, .Left, true, accept.x, accept.y), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_mouse(&c, &f, l, .Left, false, cancel.x, cancel.y), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_mouse(&c, &f, l, .Left, true, cancel.x, cancel.y), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_focused(c, f), ui.Confirm_Button.Cancel)
	testing.expect(t, !ui.focus_visible(f, f.focused), "pointer focus hides the ring")
	testing.expect_value(t, ui.confirm_mouse(&c, &f, l, .Left, false, cancel.x, cancel.y), ui.Confirm_Outcome.Cancel)
	ui.confirm_key(&c, &f, press({key = .Tab}), "")
	testing.expect(t, ui.focus_visible(f, f.focused), "Tab shows the ring again")
	ui.confirm_mouse(&c, &f, l, .Left, true, accept.x, accept.y)
	testing.expect_value(t, ui.confirm_mouse(&c, &f, l, .Left, false, accept.x, accept.y), ui.Confirm_Outcome.Accept)
	testing.expect_value(t, ui.confirm_mouse(&c, &f, l, .Left, true, inside.x, inside.y), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_mouse(&c, &f, l, .Left, false, inside.x, inside.y), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_mouse(&c, &f, l, .Left, true, 2, 2), ui.Confirm_Outcome.Cancel)
	testing.expect_value(t, ui.confirm_mouse(&c, &f, l, .Right, true, accept.x, accept.y), ui.Confirm_Outcome.None)
}

@(test)
confirm_layout_fits_narrow_windows :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 2}) {
		l := ui.confirm_layout(300, 400, scale)
		testing.expect(t, l.panel.x >= 0 && l.panel.x+l.panel.width <= 300)
		testing.expect(t, l.cancel.x+l.cancel.width <= l.accept.x)
		testing.expect(t, l.accept.y+l.accept.height <= l.panel.y+l.panel.height)
	}
}
