package ui_test

import "core:testing"
import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import "cosmos:ui"

@(test)
screen_pointer_uses_visible_paint_order :: proc(t: ^testing.T) {
	BASE :: ui.Focus_Id(1)
	OVERLAY :: ui.Focus_Id(2)
	whole := render.Rect{0, 0, 100, 100}
	s: ui.Screen
	ui.screen_init(&s)
	defer ui.screen_destroy(&s)
	ui.screen_begin(&s)
	ui.screen_add(&s, {id = BASE, rect = whole, clip = {0, 0, 50, 100}, focusable = true})
	ui.screen_add(&s, {id = OVERLAY, rect = {20, 0, 20, 100}, clip = whole, disabled = true})
	ui.screen_add(&s, {id = 3, rect = whole, clip = whole, passthrough = true})
	ui.screen_end(&s)

	for point in ([2][2]f32{{30, 10}, {50, 10}}) {
		ui.screen_move(&s, point)
		testing.expect_value(t, ui.screen_pick(&s, point), ui.Focus_Id(0))
		testing.expect(t, !ui.screen_hovered(&s, BASE) && !ui.screen_hovered(&s, OVERLAY))
		e := input.Mouse_Button_Event{button = .Left, pressed = true, x = i32(point.x), y = i32(point.y)}
		target, activated := ui.screen_button(&s, e)
		testing.expect_value(t, target, ui.Focus_Id(0))
		testing.expect(t, !activated)
		e.pressed = false
		_, activated = ui.screen_button(&s, e)
		testing.expect(t, !activated)
	}
	testing.expect_value(t, s.focus.focused, ui.Focus_Id(0))

	ui.screen_move(&s, {10, 10})
	testing.expect(t, ui.screen_hovered(&s, BASE))
	target, activated := ui.screen_button(&s, {button = .Left, pressed = true, x = 10, y = 10})
	testing.expect_value(t, target, BASE)
	testing.expect(t, ui.screen_pressed(&s, BASE) && !activated)
	testing.expect_value(t, s.focus.focused, BASE)
	testing.expect(t, !ui.focus_visible(s.focus, BASE))
	target, activated = ui.screen_button(&s, {button = .Left, x = 10, y = 10})
	testing.expect_value(t, target, BASE)
	testing.expect(t, activated && !ui.screen_pressed(&s, BASE))
}

@(test)
screen_paint_layer_is_independent_of_tab_order :: proc(t: ^testing.T) {
	whole := render.Rect{0, 0, 100, 100}
	s: ui.Screen
	ui.screen_init(&s)
	defer ui.screen_destroy(&s)
	ui.screen_begin(&s)
	ui.screen_add(&s, {id = 1, rect = whole, clip = whole, paint_layer = 1, focusable = true})
	ui.screen_add(&s, {id = 2, rect = whole, clip = whole, focusable = true})
	ui.screen_end(&s)
	testing.expect_value(t, ui.screen_pick(&s, {10, 10}), ui.Focus_Id(1))
	e := input.Key_Event{key = .Tab, pressed = true}
	testing.expect(t, ui.focus_key(&s.focus, e))
	testing.expect_value(t, s.focus.focused, ui.Focus_Id(1))
	testing.expect(t, ui.focus_key(&s.focus, e))
	testing.expect_value(t, s.focus.focused, ui.Focus_Id(2))
}

@(test)
screen_release_reports_capture_without_retargeting :: proc(t: ^testing.T) {
	OWNER :: ui.Focus_Id(1)
	OTHER :: ui.Focus_Id(2)
	whole := render.Rect{0, 0, 100, 100}
	owner := ui.Screen_Region{id = OWNER, rect = {0, 0, 50, 100}, clip = whole}
	other := ui.Screen_Region{id = OTHER, rect = {50, 0, 50, 100}, clip = whole}
	s: ui.Screen
	ui.screen_init(&s)
	defer ui.screen_destroy(&s)

	for change in ([4]string{"dragged off", "removed", "disabled", "covered"}) {
		ui.screen_begin(&s)
		ui.screen_add(&s, owner)
		ui.screen_add(&s, other)
		ui.screen_end(&s)
		target, activated := ui.screen_button(&s, {button = .Left, pressed = true, x = 10, y = 10})
		testing.expect_value(t, target, OWNER)
		testing.expect(t, !activated)

		release := input.Mouse_Button_Event{button = .Left, x = 10, y = 10}
		if change == "dragged off" {
			release.x = 60
			ui.screen_move(&s, {60, 10})
			testing.expect(t, ui.screen_hovered(&s, OTHER))
		} else {
			ui.screen_begin(&s)
			changed := owner
			switch change {
			case "removed":
			case "disabled":
				changed.disabled = true
				ui.screen_add(&s, changed)
			case "covered":
				ui.screen_add(&s, owner)
				ui.screen_add(&s, {id = OTHER, rect = owner.rect, clip = whole})
			}
			ui.screen_end(&s)
		}
		testing.expect(t, !ui.screen_hovered(&s, OWNER), change)
		testing.expect(t, !ui.screen_pressed(&s, OWNER), change)
		target, activated = ui.screen_button(&s, release)
		testing.expect_value(t, target, OWNER)
		testing.expect(t, !activated, change)
	}
}

@(test)
screen_leave_and_cancel_are_distinct :: proc(t: ^testing.T) {
	OWNER :: ui.Focus_Id(1)
	whole := render.Rect{0, 0, 100, 100}
	s: ui.Screen
	ui.screen_init(&s)
	defer ui.screen_destroy(&s)
	ui.screen_begin(&s)
	ui.screen_add(&s, {id = OWNER, rect = whole, clip = whole})
	ui.screen_end(&s)

	press := input.Mouse_Button_Event{button = .Left, pressed = true, x = 10, y = 10}
	release := input.Mouse_Button_Event{button = .Left, x = 10, y = 10}
	_, _ = ui.screen_button(&s, press)
	ui.screen_leave(&s)
	testing.expect(t, !ui.screen_hovered(&s, OWNER) && !ui.screen_pressed(&s, OWNER))
	ui.screen_move(&s, {10, 10})
	testing.expect(t, ui.screen_pressed(&s, OWNER), "re-entry restores the captured press")
	_, activated := ui.screen_button(&s, release)
	testing.expect(t, activated)

	_, _ = ui.screen_button(&s, press)
	ui.screen_cancel(&s)
	testing.expect(t, ui.screen_hovered(&s, OWNER) && !ui.screen_pressed(&s, OWNER))
	target, canceled_activation := ui.screen_button(&s, release)
	testing.expect_value(t, target, ui.Focus_Id(0))
	testing.expect(t, !canceled_activation)
}

@(test)
screen_modal_restricts_input_and_restores_focus :: proc(t: ^testing.T) {
	ROOT :: ui.Focus_Id(1)
	DIALOG :: ui.Focus_Id(2)
	whole := render.Rect{0, 0, 100, 100}
	root := ui.Screen_Region{id = ROOT, rect = whole, clip = whole, focusable = true, role = .Button, name = "Open"}
	root_action := platform.Access_Invoke_Event{id = platform.Access_Id(ROOT), action = .Invoke}
	s: ui.Screen
	ui.screen_init(&s)
	defer ui.screen_destroy(&s)
	ui.screen_begin(&s)
	ui.screen_add(&s, root)
	ui.screen_end(&s)
	testing.expect_value(t, ui.screen_access_target(&s, root_action), ROOT)

	press := input.Mouse_Button_Event{button = .Left, pressed = true, x = 10, y = 10}
	release := input.Mouse_Button_Event{button = .Left, x = 10, y = 10}
	_, _ = ui.screen_button(&s, press)
	scope := ui.screen_modal_open(&s)
	testing.expect(t, !ui.screen_hovered(&s, ROOT))
	target, activated := ui.screen_button(&s, release)
	testing.expect_value(t, target, ui.Focus_Id(0))
	testing.expect(t, !activated)

	ui.screen_begin(&s)
	ui.screen_add(&s, root)
	ui.screen_add(&s, {id = DIALOG, rect = {20, 0, 50, 100}, clip = whole, scope = scope,
	                   focusable = true, role = .Button, name = "Close"})
	ui.screen_end(&s)
	testing.expect_value(t, ui.screen_pick(&s, {10, 10}), ui.Focus_Id(0))
	testing.expect_value(t, ui.screen_pick(&s, {30, 10}), DIALOG)
	testing.expect(t, ui.focus_key(&s.focus, {key = .Tab, pressed = true}))
	testing.expect_value(t, s.focus.focused, DIALOG)
	testing.expect_value(t, ui.screen_access_target(&s, root_action), ui.Focus_Id(0))
	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)
	ui.screen_access(&s, &tree)
	testing.expect_value(t, len(tree.nodes), 1)
	if len(tree.nodes) == 1 {testing.expect_value(t, tree.nodes[0].id, platform.Access_Id(DIALOG))}

	press.x, release.x = 30, 30
	_, _ = ui.screen_button(&s, press)
	ui.screen_modal_close(&s, scope)
	testing.expect(t, ui.screen_hovered(&s, ROOT))
	testing.expect_value(t, s.focus.focused, ROOT)
	target, activated = ui.screen_button(&s, release)
	testing.expect_value(t, target, ui.Focus_Id(0))
	testing.expect(t, !activated)
}

@(test)
screen_tab_can_reach_a_fully_clipped_control :: proc(t: ^testing.T) {
	FIRST :: ui.Focus_Id(20)
	OFFSCREEN :: ui.Focus_Id(10)
	viewport := render.Rect{0, 0, 100, 100}
	s: ui.Screen
	ui.screen_init(&s)
	defer ui.screen_destroy(&s)
	ui.screen_begin(&s)
	ui.screen_add(&s, {id = FIRST, rect = {0, 80, 100, 20}, clip = viewport, focusable = true})
	ui.screen_add(&s, {id = 30, rect = viewport, clip = viewport, disabled = true, focusable = true})
	ui.screen_add(&s, {id = OFFSCREEN, rect = {0, 100, 100, 20}, clip = viewport, focusable = true})
	ui.screen_end(&s)

	key := input.Key_Event{key = .Tab, pressed = true}
	testing.expect(t, ui.focus_key(&s.focus, key))
	testing.expect_value(t, s.focus.focused, FIRST)
	testing.expect(t, ui.focus_key(&s.focus, key))
	testing.expect_value(t, s.focus.focused, OFFSCREEN)
	testing.expect(t, ui.focus_visible(s.focus, OFFSCREEN))
	testing.expect_value(t, ui.screen_pick(&s, {10, 110}), ui.Focus_Id(0))
}

@(test)
screen_access_publishes_clipped_geometry_and_role_actions :: proc(t: ^testing.T) {
	GROUP :: ui.Focus_Id(1)
	CHECK :: ui.Focus_Id(2)
	MENU :: ui.Focus_Id(3)
	viewport := render.Rect{0, 0, 100, 100}
	s: ui.Screen
	ui.screen_init(&s)
	defer ui.screen_destroy(&s)
	ui.screen_begin(&s)
	ui.screen_add(&s, {id = GROUP, rect = viewport, clip = viewport, passthrough = true,
	                   role = .Group, name = "Options"})
	ui.screen_add(&s, {id = CHECK, rect = {10, 90, 30, 20}, clip = viewport, focusable = true,
	                   role = .Check_Box, name = "Toggle option", state = {.Checked}, parent = platform.Access_Id(GROUP)})
	ui.screen_add(&s, {id = MENU, rect = {0, 100, 30, 20}, clip = viewport,
	                   role = .Menu_Item, name = "More", state = {.Collapsed}})
	ui.screen_add(&s, {id = 4, rect = viewport, clip = viewport, role = .Button})
	ui.screen_end(&s)

	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)
	ui.screen_access(&s, &tree)
	testing.expect_value(t, len(tree.nodes), 3)
	if len(tree.nodes) == 3 {
		testing.expect_value(t, tree.nodes[1].parent, platform.Access_Id(GROUP))
		testing.expect_value(t, tree.nodes[1].bounds, [4]f32{10, 90, 30, 10})
		testing.expect(t, .Checked in tree.nodes[1].states && .Focusable in tree.nodes[1].states)
		testing.expect_value(t, tree.nodes[2].bounds.w, f32(0))
	}
	testing.expect_value(t, ui.screen_access_target(&s, {id = platform.Access_Id(CHECK), action = .Toggle}), CHECK)
	testing.expect_value(t, ui.screen_access_target(&s, {id = platform.Access_Id(CHECK), action = .Invoke}), ui.Focus_Id(0))
	testing.expect_value(t, ui.screen_access_target(&s, {id = platform.Access_Id(MENU), action = .Expand}), MENU)
	testing.expect_value(t, ui.screen_access_target(&s, {id = platform.Access_Id(MENU), action = .Invoke}), ui.Focus_Id(0))
	testing.expect_value(t, ui.screen_access_target(&s, {id = 4, action = .Invoke}), ui.Focus_Id(0))
}
