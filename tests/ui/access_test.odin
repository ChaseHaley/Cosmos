package ui_test

import "core:testing"
import "cosmos:platform"
import "cosmos:ui"

@(private = "file")
WIDTH :: f32(800)
@(private = "file")
HEIGHT :: f32(600)
@(private = "file")
SCALE :: f32(1.5)

@(private = "file")
States :: bit_set[platform.Access_State;u16]

// Ids a widget derives for its parts stay clear of the window's 0, of each other and of the small ids apps
// give their widgets, so no two nodes of a tree share one.
@(test)
access_part_ids_are_never_zero_and_distinct :: proc(t: ^testing.T) {
	seen := make(map[platform.Access_Id]struct{})
	defer delete(seen)
	for base in 0..<64 {
		for part in 0..<64 {
			id := ui.access_part(platform.Access_Id(base), u64(part))
			testing.expect(t, id != 0, "a part took the window's id")
			testing.expect(t, u64(id) >= 64, "a part took a small app id")
			testing.expect(t, id not_in seen, "two parts share an id")
			seen[id] = {}
		}
	}
}

@(private = "file")
expect_node :: proc(
	t: ^testing.T,
	node: platform.Access_Node,
	id, parent: platform.Access_Id,
	role: platform.Access_Role,
	name: string,
	bounds: [4]f32,
	states: States,
	loc := #caller_location,
) {
	testing.expect_value(t, node.id, id, loc)
	testing.expect_value(t, node.parent, parent, loc)
	testing.expect_value(t, node.role, role, loc)
	testing.expect_value(t, node.name, name, loc)
	testing.expect_value(t, node.bounds, bounds, loc)
	testing.expect_value(t, node.states, states, loc)
}

// A screen reader gets each row the menu shows as a Menu_Item named by its label, where it is drawn, with
// the state it shows; separators are not items, and a submenu hangs under the row it opens from.
@(test)
menu_access_lists_its_rows_and_submenu :: proc(t: ^testing.T) {
	MENU :: platform.Access_Id(20)
	SUB :: platform.Access_Id(30)
	PARENT :: platform.Access_Id(7)
	m: ui.Menu
	ui.menu_init(&m)
	defer ui.menu_destroy(&m)
	ui.menu_anchor(&m, 100, 80)
	_ = ui.menu_add(&m, {label = "Open", shortcut = "Ctrl+O", enabled = true})
	_ = ui.menu_add(&m, {label = "Paste"})
	_ = ui.menu_add(&m, {separator = true})
	_ = ui.menu_add(&m, {label = "Wrap lines", enabled = true, checked = true})
	_ = ui.menu_add(&m, {label = "Speed", enabled = true, submenu = true})
	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)
	ui.menu_access(&m, &tree, PARENT, MENU, "Edit", WIDTH, HEIGHT, SCALE)

	if !testing.expect_value(t, len(tree.nodes), 5) {return}
	surface, _ := ui.menu_layout(&m, WIDTH, HEIGHT, SCALE)
	expect_node(t, tree.nodes[0], MENU, PARENT, .Menu, "Edit", ui.access_bounds(surface), {})
	rows := [?]struct {
		row:    int,
		name:   string,
		states: States,
	} {
		{0, "Open", {.Focusable}},
		{1, "Paste", {.Disabled}},
		{3, "Wrap lines", {.Focusable, .Checked}},
		{4, "Speed", {.Focusable, .Collapsed}},
	}
	for r, i in rows {
		bounds := ui.access_bounds(ui.menu_row_rect(&m, r.row, WIDTH, HEIGHT, SCALE))
		id := ui.access_part(MENU, u64(r.row))
		expect_node(t, tree.nodes[i + 1], id, MENU, .Menu_Item, r.name, bounds, r.states)
		row, ok := ui.menu_access_row(&m, MENU, id)
		testing.expect(t, ok && row == r.row, "an item's id does not map back to its row")
	}
	_, separator := ui.menu_access_row(&m, MENU, ui.access_part(MENU, 2))
	testing.expect(t, !separator, "a separator maps to a row")

	sub: ui.Submenu
	ui.menu_init(&sub.menu)
	defer ui.menu_destroy(&sub.menu)
	_ = ui.menu_add(&sub.menu, {label = "0.5×", enabled = true})
	_ = ui.menu_add(&sub.menu, {label = "1×", enabled = true, checked = true})
	ui.submenu_place(&sub, &m, 4, 160, true, WIDTH, HEIGHT, SCALE)
	ui.access_begin(&tree)
	ui.menu_access(&m, &tree, PARENT, MENU, "Edit", WIDTH, HEIGHT, SCALE, sub.row)
	ui.submenu_access(&sub, &tree, MENU, SUB, "Speed", WIDTH, HEIGHT, SCALE)

	if !testing.expect_value(t, len(tree.nodes), 8) {return}
	testing.expect_value(t, tree.nodes[4].states, States{.Focusable, .Expanded})
	sub_surface, _ := ui.menu_layout(&sub.menu, WIDTH, HEIGHT, SCALE)
	speed := ui.access_part(MENU, 4)
	expect_node(t, tree.nodes[5], SUB, speed, .Menu, "Speed", ui.access_bounds(sub_surface), {})
	for name, row in ([?]string{"0.5×", "1×"}) {
		bounds := ui.access_bounds(ui.menu_row_rect(&sub.menu, row, WIDTH, HEIGHT, SCALE))
		states := row == 1 ? States{.Focusable, .Checked} : States{.Focusable}
		expect_node(t, tree.nodes[6 + row], ui.access_part(SUB, u64(row)), SUB, .Menu_Item, name, bounds, states)
	}
}

// A menu taller than the window lists only the rows it shows, the selected one among them, so a screen
// reader is never told of rows off the screen.
@(test)
menu_access_leaves_out_rows_scrolled_away :: proc(t: ^testing.T) {
	MENU :: platform.Access_Id(20)
	m: ui.Menu
	ui.menu_init(&m)
	defer ui.menu_destroy(&m)
	for _ in 0..<40 {_ = ui.menu_add(&m, {label = "row", enabled = true})}
	ui.menu_select(&m, 30)
	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)
	ui.menu_access(&m, &tree, 0, MENU, "Long", WIDTH, 300, 1)

	_, shown := ui.menu_layout(&m, WIDTH, 300, 1)
	if !testing.expect(t, shown < 40, "every row fits") {return}
	testing.expect_value(t, len(tree.nodes), 1 + shown)
	selected := ui.access_part(MENU, 30)
	listed := false
	for node in tree.nodes[1:] {
		row, _ := ui.menu_access_row(&m, MENU, node.id)
		testing.expect_value(t, node.bounds, ui.access_bounds(ui.menu_row_rect(&m, row, WIDTH, 300, 1)))
		on_window := node.bounds[1] >= 0 && node.bounds[1] + node.bounds[3] <= 300
		testing.expect(t, on_window, "a listed row is off the window")
		if node.id == selected {listed = true}
	}
	testing.expect(t, listed, "the selected row is not listed")
}

// A submenu whose row the menu has scrolled away hangs under the menu itself, so the tree keeps every
// parent before its children and the platform still takes it.
@(test)
submenu_access_outlives_its_row_scrolling_away :: proc(t: ^testing.T) {
	MENU :: platform.Access_Id(20)
	SUB :: platform.Access_Id(30)
	m: ui.Menu
	ui.menu_init(&m)
	defer ui.menu_destroy(&m)
	_ = ui.menu_add(&m, {label = "Speed", enabled = true, submenu = true})
	for _ in 1..<40 {_ = ui.menu_add(&m, {label = "row", enabled = true})}
	sub: ui.Submenu
	ui.menu_init(&sub.menu)
	defer ui.menu_destroy(&sub.menu)
	_ = ui.menu_add(&sub.menu, {label = "1×", enabled = true})
	ui.submenu_place(&sub, &m, 0, 160, true, WIDTH, 300, 1)
	ui.menu_select(&m, 30)
	ui.menu_reveal(&m, WIDTH, 300, 1)
	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)
	ui.menu_access(&m, &tree, 0, MENU, "Long", WIDTH, 300, 1, sub.row)
	ui.submenu_access(&sub, &tree, MENU, SUB, "Speed", WIDTH, 300, 1)

	seen := make(map[platform.Access_Id]struct{})
	defer delete(seen)
	submenu_parent := platform.Access_Id(0)
	for node in tree.nodes {
		testing.expect(t, node.id != ui.access_part(MENU, 0), "the scrolled-away row is listed")
		testing.expect(t, node.parent == 0 || node.parent in seen, "a node comes before its parent")
		seen[node.id] = {}
		if node.id == SUB {submenu_parent = node.parent}
	}
	testing.expect_value(t, submenu_parent, MENU)
	testing.expect(t, ui.access_part(SUB, 0) in seen, "the submenu's row is missing")
}

// The dialog's buttons are named by their labels and take their focus ids, so the focus the dialog gives
// Accept is the node a screen reader reads; invoking a button answers as clicking it would.
@(test)
confirm_access_buttons_carry_focus_and_answer :: proc(t: ^testing.T) {
	CONTROL :: ui.Focus_Id(1)
	DIALOG :: ui.Focus_Id(10)
	NODE :: platform.Access_Id(50)
	c: ui.Confirm
	f: ui.Focus
	ui.focus_init(&f)
	defer ui.focus_destroy(&f)
	ui.focus_set(&f, CONTROL, false)
	ui.confirm_open(&c, &f, DIALOG, show_option = true)
	ui.focus_frame_begin(&f)
	ui.focus_add(&f, CONTROL)
	ui.confirm_focus_add(&c, &f)
	ui.focus_frame_end(&f)
	l := ui.confirm_layout(WIDTH, HEIGHT, SCALE, c.extended, c.show_option)
	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)
	ui.confirm_access(&c, &tree, 0, NODE, "Delete the clip?", l, "Delete", "Don't ask again")

	if !testing.expect_value(t, len(tree.nodes), 4) {return}
	option, cancel, accept := platform.Access_Id(10), platform.Access_Id(11), platform.Access_Id(12)
	expect_node(t, tree.nodes[0], NODE, 0, .Dialog, "Delete the clip?", ui.access_bounds(l.panel), {})
	option_bounds := ui.access_bounds(l.option)
	expect_node(t, tree.nodes[1], option, NODE, .Check_Box, "Don't ask again", option_bounds, {.Focusable})
	expect_node(t, tree.nodes[2], cancel, NODE, .Button, "Cancel", ui.access_bounds(l.cancel), {.Focusable})
	expect_node(t, tree.nodes[3], accept, NODE, .Button, "Delete", ui.access_bounds(l.accept), {.Focusable})
	testing.expect_value(t, ui.access_focused(f), accept)

	invoke := platform.Access_Invoke_Event{id = accept, action = .Invoke}
	testing.expect_value(t, ui.confirm_access_invoke(&c, &f, invoke), ui.Confirm_Outcome.Accept)
	invoke.id = cancel
	testing.expect_value(t, ui.confirm_access_invoke(&c, &f, invoke), ui.Confirm_Outcome.Cancel)
	invoke.id = NODE
	testing.expect_value(t, ui.confirm_access_invoke(&c, &f, invoke), ui.Confirm_Outcome.None)
	toggle := platform.Access_Invoke_Event{id = option, action = .Toggle}
	testing.expect_value(t, ui.confirm_access_invoke(&c, &f, toggle), ui.Confirm_Outcome.Changed)
	testing.expect(t, c.option, "Toggle left the option unchecked")
	ui.access_begin(&tree)
	ui.confirm_access(&c, &tree, 0, NODE, "Delete the clip?", l, "Delete", "Don't ask again")
	testing.expect_value(t, tree.nodes[1].states, States{.Focusable, .Checked})

	// A screen reader focuses the dialog's controls with the ring, but not the window's control under it.
	testing.expect(t, ui.access_focus_request(&f, {id = cancel}), "the request missed Cancel")
	testing.expect(t, f.focused == ui.Focus_Id(cancel) && ui.focus_visible(f, f.focused), "Cancel has no ring")
	testing.expect(t, !ui.access_focus_request(&f, {id = platform.Access_Id(CONTROL)}), "focus left the dialog")
	testing.expect_value(t, ui.access_focused(f), cancel)
}
