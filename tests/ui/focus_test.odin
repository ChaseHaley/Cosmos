package ui_test

import "cosmos:input"
import "core:testing"
import "cosmos:ui"

@(private="file")
tab :: proc(f: ^ui.Focus, modifiers := input.Modifiers{}) -> bool {
	return ui.focus_key(f, {key = .Tab, modifiers = modifiers, pressed = true})
}

// Registers one frame's controls in `root`, then those in `scope` when it is open.
@(private="file")
build :: proc(f: ^ui.Focus, root: []ui.Focus_Id, scoped: []ui.Focus_Id = nil, scope := ui.Focus_Scope(0)) {
	ui.focus_frame_begin(f)
	for id in root {ui.focus_add(f, id)}
	for id in scoped {ui.focus_add(f, id, scope)}
	ui.focus_frame_end(f)
}

// Tab follows the order the app registered, not the ids' values, and wraps at both ends.
@(test)
focus_tab_walks_the_registered_order_and_wraps :: proc(t: ^testing.T) {
	f: ui.Focus
	ui.focus_init(&f)
	defer ui.focus_destroy(&f)
	build(&f, {30, 10, 20})
	testing.expect(t, tab(&f))
	testing.expect_value(t, f.focused, ui.Focus_Id(30))
	testing.expect(t, tab(&f))
	testing.expect_value(t, f.focused, ui.Focus_Id(10))
	testing.expect(t, tab(&f))
	testing.expect_value(t, f.focused, ui.Focus_Id(20))
	testing.expect(t, tab(&f))
	testing.expect_value(t, f.focused, ui.Focus_Id(30))
	testing.expect(t, tab(&f, {.Shift}))
	testing.expect_value(t, f.focused, ui.Focus_Id(20))

	// With nothing focused, Shift+Tab starts at the last control.
	ui.focus_set(&f, 0, false)
	testing.expect(t, tab(&f, {.Shift}))
	testing.expect_value(t, f.focused, ui.Focus_Id(20))

	// A frame in progress does not change the order keys walk until it completes.
	ui.focus_frame_begin(&f)
	ui.focus_add(&f, 20)
	ui.focus_add(&f, 30)
	testing.expect(t, tab(&f))
	testing.expect_value(t, f.focused, ui.Focus_Id(30))
	ui.focus_frame_end(&f)
	testing.expect(t, tab(&f))
	testing.expect_value(t, f.focused, ui.Focus_Id(20))
}

// A modal scope keeps Tab among its own controls and gives focus back to the window's control on close,
// through nested scopes too.
@(test)
focus_scope_traps_traversal_and_restores_focus :: proc(t: ^testing.T) {
	f: ui.Focus
	ui.focus_init(&f)
	defer ui.focus_destroy(&f)
	root := []ui.Focus_Id{1, 2, 3}
	build(&f, root)
	ui.focus_set(&f, 2, true)
	dialog := ui.focus_scope_open(&f)
	testing.expect_value(t, f.focused, ui.Focus_Id(2))
	ui.focus_set(&f, 10, true)
	build(&f, root, {10, 11}, dialog)
	testing.expect_value(t, f.focused, ui.Focus_Id(10))
	testing.expect(t, tab(&f))
	testing.expect_value(t, f.focused, ui.Focus_Id(11))
	testing.expect(t, tab(&f))
	testing.expect_value(t, f.focused, ui.Focus_Id(10))
	testing.expect(t, tab(&f, {.Shift}))
	testing.expect_value(t, f.focused, ui.Focus_Id(11))

	menu := ui.focus_scope_open(&f)
	ui.focus_set(&f, 20, true)
	ui.focus_frame_begin(&f)
	for id in root {ui.focus_add(&f, id)}
	ui.focus_add(&f, 10, dialog)
	ui.focus_add(&f, 11, dialog)
	ui.focus_add(&f, 20, menu)
	ui.focus_frame_end(&f)
	testing.expect(t, tab(&f))
	testing.expect_value(t, f.focused, ui.Focus_Id(20))
	ui.focus_scope_close(&f, menu)
	testing.expect_value(t, f.focused, ui.Focus_Id(11))

	ui.focus_scope_close(&f, dialog)
	testing.expect_value(t, f.focused, ui.Focus_Id(2))
	build(&f, root)
	testing.expect_value(t, f.focused, ui.Focus_Id(2))
	testing.expect(t, tab(&f))
	testing.expect_value(t, f.focused, ui.Focus_Id(3))
}

// A focused control a frame no longer registers loses focus: to nothing in the window, to the first
// control inside a modal scope, and a control outside the open scope counts as gone.
@(test)
focus_moves_off_a_control_that_disappears :: proc(t: ^testing.T) {
	f: ui.Focus
	ui.focus_init(&f)
	defer ui.focus_destroy(&f)
	build(&f, {1, 2, 3})
	ui.focus_set(&f, 2, true)
	build(&f, {1, 2, 3})
	testing.expect_value(t, f.focused, ui.Focus_Id(2))
	build(&f, {1, 3})
	testing.expect_value(t, f.focused, ui.Focus_Id(0))
	testing.expect(t, f.changed, "losing focus is a change")

	ui.focus_set(&f, 3, true)
	dialog := ui.focus_scope_open(&f)
	ui.focus_set(&f, 11, true)
	build(&f, {1, 3}, {10, 11}, dialog)
	testing.expect_value(t, f.focused, ui.Focus_Id(11))
	build(&f, {1, 3}, {10}, dialog)
	testing.expect_value(t, f.focused, ui.Focus_Id(10))
	ui.focus_set(&f, 1, false)
	build(&f, {1, 3}, {10}, dialog)
	testing.expect_value(t, f.focused, ui.Focus_Id(10))
	ui.focus_scope_close(&f, dialog)
	testing.expect_value(t, f.focused, ui.Focus_Id(3))
}

// As the web's :focus-visible: a pointer press focuses without the ring, and Tab brings it back.
@(test)
focus_ring_follows_the_input_that_moved_focus :: proc(t: ^testing.T) {
	f: ui.Focus
	ui.focus_init(&f)
	defer ui.focus_destroy(&f)
	build(&f, {1, 2})
	testing.expect(t, !ui.focus_visible(f, 0), "no control has no ring")
	ui.focus_set(&f, 1, false)
	testing.expect_value(t, f.focused, ui.Focus_Id(1))
	testing.expect(t, !ui.focus_visible(f, 1))
	testing.expect(t, tab(&f))
	testing.expect(t, ui.focus_visible(f, 2))
	testing.expect(t, !ui.focus_visible(f, 1), "only the focused control rings")
	ui.focus_set(&f, 1, false)
	testing.expect(t, !ui.focus_visible(f, 1))
	testing.expect(t, ui.focus_move(&f, false), "an arrow the app routes is keyboard navigation")
	testing.expect(t, ui.focus_visible(f, 2))
}

// Chords on Tab belong to the app and the system; only plain Tab and Shift+Tab press traverse.
@(test)
focus_leaves_tab_chords_and_releases_alone :: proc(t: ^testing.T) {
	f: ui.Focus
	ui.focus_init(&f)
	defer ui.focus_destroy(&f)
	build(&f, {1, 2})
	ui.focus_set(&f, 1, false)
	testing.expect(t, !tab(&f, {.Control}))
	testing.expect(t, !tab(&f, {.Control, .Shift}))
	testing.expect(t, !tab(&f, {.Alt}))
	testing.expect(t, !tab(&f, {.Super}))
	testing.expect(t, !ui.focus_key(&f, {key = .Tab}), "a release does not move focus")
	testing.expect(t, !ui.focus_key(&f, {key = .Arrow_Down, pressed = true}))
	testing.expect_value(t, f.focused, ui.Focus_Id(1))
	testing.expect(t, !ui.focus_visible(f, 1))
	testing.expect(t, tab(&f, {.Shift, .Caps_Lock}), "lock keys are not chords")
	testing.expect_value(t, f.focused, ui.Focus_Id(2))
}

// With nothing registered Tab is not taken, and a focus the app set to nothing it built is dropped.
@(test)
focus_frame_without_focusables :: proc(t: ^testing.T) {
	f: ui.Focus
	ui.focus_init(&f)
	defer ui.focus_destroy(&f)
	build(&f, {})
	testing.expect(t, !tab(&f))
	testing.expect_value(t, f.focused, ui.Focus_Id(0))
	testing.expect(t, !f.changed)
	ui.focus_set(&f, 4, true)
	build(&f, {})
	testing.expect_value(t, f.focused, ui.Focus_Id(0))
	testing.expect(t, !f.changed, "focus that never reached a frame did not change")
}

// `changed` reports a frame that ended with a different control focused than the one before it.
@(test)
focus_changed_reports_each_completed_move_once :: proc(t: ^testing.T) {
	f: ui.Focus
	ui.focus_init(&f)
	defer ui.focus_destroy(&f)
	build(&f, {1, 2})
	testing.expect(t, tab(&f))
	build(&f, {1, 2})
	testing.expect(t, f.changed)
	build(&f, {1, 2})
	testing.expect(t, !f.changed, "the next frame has nothing new")
	testing.expect(t, tab(&f))
	testing.expect(t, tab(&f, {.Shift}))
	build(&f, {1, 2})
	testing.expect(t, !f.changed, "moving away and back within a frame is no change")
}
