package ui_test

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:testing"
import "core:time"
import "cosmos:font"
import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import "cosmos:search"
import "cosmos:textedit"
import "cosmos:ui"

@(private = "file")
PARENT :: platform.Access_Id(3)
@(private = "file")
ID :: platform.Access_Id(7)

@(private = "file")
ANCHOR :: ui.Dropdown_Anchor {
	field  = {10, 10, 300, 24},
	row    = {10, 10, 300, 24},
	bounds = {0, 0, 800, 600},
}

@(private = "file")
rect_bounds :: proc(r: render.Rect) -> [4]f32 {
	return {r.x, r.y, r.width, r.height}
}

@(private = "file")
center :: proc(node: platform.Access_Node) -> (x, y: f32) {
	return node.bounds[0] + node.bounds[2] / 2, node.bounds[1] + node.bounds[3] / 2
}

@(private = "file")
named :: proc(nodes: []platform.Access_Node, name: string) -> (platform.Access_Node, bool) {
	for node in nodes {if node.name == name {return node, true}}
	return {}, false
}

// A tree the platform takes: ids are unique and every node's parent is `root` or a node before it.
@(private = "file")
expect_tree :: proc(t: ^testing.T, nodes: []platform.Access_Node, root: platform.Access_Id) {
	for node, i in nodes {
		testing.expect(t, node.id != 0)
		placed := node.parent == root
		for earlier in nodes[:i] {
			testing.expect(t, earlier.id != node.id)
			placed ||= earlier.id == node.parent
		}
		testing.expectf(t, placed, "%q comes before its parent", node.name)
	}
}

@(private = "file")
text_open :: proc(t: ^testing.T, text: ^ui.Text) -> (^font.System, bool) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return nil, false}
	if !testing.expect(t, ui.text_init(text, fonts, nil, 16)) {
		font.system_destroy(fonts)
		return nil, false
	}
	return fonts, true
}

@(private = "file")
access_window_open :: proc(t: ^testing.T, p: ^platform.Platform, name: string) -> (input.Window_Id, bool) {
	app_id := fmt.tprintf("Cosmos.Test.Access.Widgets.%s.%d", name, os.get_pid())
	if !testing.expect_value(t, platform.init(p, app_id), platform.Init_Result.Primary) {return 0, false}
	window, err := platform.window_create(p, {hidden = true, title = "Widget access", width = 400, height = 300})
	return window, testing.expect_value(t, err, platform.Error.None)
}

// Closed, the dropdown is one collapsed Combo_Box on its field showing the shown label; open, it holds a
// List of its options where they draw, so a press at an option's centre picks that option, and the
// requests assistive technology makes do what Escape and a press do.
@(test)
dropdown_access_describes_the_field_and_the_options_where_they_draw :: proc(t: ^testing.T) {
	choices := [?]string{"system", "light", "dark"}
	labels := [?]string{"System", "Light", "Dark"}
	c := ui.Dropdown_Choices {
		choices = choices[:],
		labels  = labels[:],
		value   = "light",
	}
	d: ui.Dropdown
	ui.dropdown_init(&d)
	defer ui.dropdown_destroy(&d)
	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)

	focus := ui.dropdown_access(&d, c, ANCHOR, &tree, PARENT, ID, "Theme", "Light", false, 1)
	testing.expect_value(t, focus, ID)
	if !testing.expect_value(t, len(tree.nodes), 1) {return}
	combo := tree.nodes[0]
	testing.expect_value(t, combo.id, ID)
	testing.expect_value(t, combo.parent, PARENT)
	testing.expect_value(t, combo.role, platform.Access_Role.Combo_Box)
	testing.expect_value(t, combo.name, "Theme")
	testing.expect_value(t, combo.value, "Light")
	testing.expect_value(t, combo.states, bit_set[platform.Access_State;u16]{.Focusable, .Collapsed})
	testing.expect_value(t, combo.bounds, rect_bounds(ANCHOR.field))
	expand := ui.dropdown_access_invoke(&d, c, ID, {id = ID, action = .Expand}, false)
	_, opens := expand.(ui.Dropdown_Open)
	testing.expect(t, opens)

	ui.dropdown_open(&d, c)
	ui.access_begin(&tree)
	focus = ui.dropdown_access(&d, c, ANCHOR, &tree, PARENT, ID, "Theme", "Light", true, 1)
	nodes := tree.nodes[:]
	if !testing.expect_value(t, len(nodes), 2 + len(choices)) {return}
	expect_tree(t, nodes, PARENT)
	testing.expect_value(t, nodes[0].states, bit_set[platform.Access_State;u16]{.Focusable, .Expanded})
	list := nodes[1]
	testing.expect_value(t, list.role, platform.Access_Role.List)
	testing.expect_value(t, list.parent, ID)
	popup := ui.dropdown_rect(&d, c, ANCHOR, 1)
	testing.expect_value(t, list.bounds, rect_bounds(popup))
	testing.expect_value(t, focus, ui.access_part(ID, 1))
	for item, i in nodes[2:] {
		testing.expect_value(t, item.id, ui.access_part(ID, u64(i)))
		testing.expect_value(t, item.parent, list.id)
		testing.expect_value(t, item.role, platform.Access_Role.List_Item)
		testing.expect_value(t, item.name, labels[i])
		testing.expect_value(t, .Selected in item.states, i == 1)
		testing.expect_value(t, item.bounds[3], ui.CHOICE_HEIGHT)
		testing.expect(t, render.rect_contains(popup, item.bounds[0], item.bounds[1]))
		x, y := center(item)
		testing.expect_value(t, ui.dropdown_press(&d, c, ANCHOR, nil, x, y, false, 1), ui.Dropdown_Outcome.Chosen)
		testing.expect_value(t, ui.dropdown_highlighted(&d, c), i)
	}

	// Invoking an option chooses it as the press did; Collapse closes the list as Escape does.
	chosen := ui.dropdown_access_invoke(&d, c, ID, {id = ui.access_part(ID, 0), action = .Invoke}, true)
	testing.expect_value(t, chosen, ui.Dropdown_Access_Outcome(ui.Dropdown_Outcome.Chosen))
	testing.expect_value(t, ui.dropdown_highlighted(&d, c), 0)
	escape, _ := ui.dropdown_key(&d, c, ANCHOR, input.Key_Event{key = .Escape, pressed = true}, 1)
	collapse := ui.dropdown_access_invoke(&d, c, ID, {id = ID, action = .Collapse}, true)
	testing.expect_value(t, collapse, ui.Dropdown_Access_Outcome(escape))
	expand = ui.dropdown_access_invoke(&d, c, ID, {id = ID, action = .Expand}, true)
	testing.expect_value(t, expand, ui.Dropdown_Access_Outcome(ui.Dropdown_Outcome.None))
}

// Past the 32nd choice and filtered by a search, an option keeps the id of its index into the choices,
// shows its mark, and invoking it chooses the same option a press on it does. The search field and its
// `.*` toggle describe what they show and the toggle does what a press on it does.
@(test)
dropdown_access_keeps_choice_ids_through_a_search_past_the_thirty_second :: proc(t: ^testing.T) {
	names: [40]string
	for &name, i in names {name = fmt.tprintf("item %02d", i)}
	marked: [40]bool
	marked[35] = true
	c := ui.Dropdown_Choices {
		choices      = names[:],
		marked       = marked[:],
		multiple     = true,
		searchable   = true,
		regex_toggle = true,
	}
	d: ui.Dropdown
	ui.dropdown_init(&d)
	defer ui.dropdown_destroy(&d)
	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)
	ui.dropdown_open(&d, c)
	ui.dropdown_text(&d, c, "item 3")

	ui.dropdown_access(&d, c, ANCHOR, &tree, PARENT, ID, "Files", "1 file", true, 1)
	nodes := tree.nodes[:]
	expect_tree(t, nodes, PARENT)
	search_field, has_search := named(nodes, "Search fonts")
	if !testing.expect(t, has_search) {return}
	testing.expect_value(t, search_field.role, platform.Access_Role.Text_Field)
	testing.expect_value(t, search_field.parent, ID)
	testing.expect_value(t, search_field.value, "item 3")
	items := 0
	for node in nodes {
		if node.role != .List_Item {continue}
		items += 1
		index, parsed := strconv.parse_int(node.name[len("item "):], 10)
		if !testing.expectf(t, parsed, "%q is not a choice of the list", node.name) {continue}
		testing.expectf(t, node.id == ui.access_part(ID, u64(index)), "%s takes its choice index", node.name)
		testing.expect_value(t, .Checked in node.states, index == 35)
		testing.expect_value(t, .Selected in node.states, index == 30)
	}
	testing.expect_value(t, items, ui.CHOICE_LIST_ROWS)

	option, shown := named(nodes, "item 37")
	if !testing.expect(t, shown) {return}
	invoked := ui.dropdown_access_invoke(&d, c, ID, {id = option.id, action = .Invoke}, true)
	testing.expect_value(t, invoked, ui.Dropdown_Access_Outcome(ui.Dropdown_Outcome.Chosen))
	testing.expect_value(t, ui.dropdown_highlighted(&d, c), 37)
	ui.access_begin(&tree)
	focus := ui.dropdown_access(&d, c, ANCHOR, &tree, PARENT, ID, "Files", "1 file", true, 1)
	testing.expect_value(t, focus, option.id)
	nodes = tree.nodes[:]
	d.list.index = 0
	x, y := center(option)
	testing.expect_value(t, ui.dropdown_press(&d, c, ANCHOR, nil, x, y, false, 1), ui.Dropdown_Outcome.Chosen)
	testing.expect_value(t, ui.dropdown_highlighted(&d, c), 37)

	regex, has_regex := named(nodes, "Regular expression")
	if !testing.expect(t, has_regex) {return}
	testing.expect_value(t, regex.role, platform.Access_Role.Check_Box)
	testing.expect(t, .Checked not_in regex.states)
	toggled := ui.dropdown_access_invoke(&d, c, ID, {id = regex.id, action = .Toggle}, true)
	testing.expect_value(t, toggled, ui.Dropdown_Access_Outcome(ui.Dropdown_Outcome.Changed))
	testing.expect(t, d.regex)
	x, y = center(regex)
	testing.expect_value(t, ui.dropdown_press(&d, c, ANCHOR, nil, x, y, false, 1), ui.Dropdown_Outcome.Changed)
	testing.expect(t, !d.regex)
}

@(test)
dropdown_access_commits_combo_focus_when_the_focused_child_does_not_fit :: proc(t: ^testing.T) {
	p: platform.Platform
	window, ok := access_window_open(t, &p, "Dropdown")
	defer testing.expect_value(t, platform.destroy(&p), platform.Error.None)
	if !ok {return}
	choices := [?]string{"A", "B"}
	c := ui.Dropdown_Choices{choices = choices[:], value = "B", searchable = true, font_filter = true}
	d: ui.Dropdown
	ui.dropdown_init(&d)
	defer ui.dropdown_destroy(&d)
	ui.dropdown_open(&d, c)
	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)

	narrow := ANCHOR
	narrow.bounds.width = 16
	testing.expect_value(t, ui.dropdown_rect(&d, c, narrow, 1).width, 0)
	testing.expect_value(t, ui.dropdown_highlighted(&d, c), 1)
	focus := ui.dropdown_access(&d, c, narrow, &tree, 0, ID, "Font", "B", true, 1)
	testing.expect_value(t, ui.access_commit(&tree, &p, window, focus), platform.Error.None)
	testing.expect_value(t, focus, ID)
	if !testing.expect_value(t, len(tree.nodes), 1) {return}
	testing.expect(t, .Expanded in tree.nodes[0].states)

	ui.dropdown_key(&d, c, narrow, {key = .Tab, pressed = true}, 1)
	ui.access_begin(&tree)
	focus = ui.dropdown_access(&d, c, narrow, &tree, 0, ID, "Font", "B", true, 1)
	testing.expect_value(t, ui.access_commit(&tree, &p, window, focus), platform.Error.None)
	testing.expect_value(t, focus, ID)

	// A popup can also fit while its inset switch still has no width.
	narrow.bounds.width = 20
	testing.expect(t, ui.dropdown_rect(&d, c, narrow, 1).width > 0)
	ui.access_begin(&tree)
	focus = ui.dropdown_access(&d, c, narrow, &tree, 0, ID, "Font", "B", true, 1)
	testing.expect_value(t, ui.access_commit(&tree, &p, window, focus), platform.Error.None)
	testing.expect_value(t, focus, ID)
	_, has_switch := named(tree.nodes[:], "Show all fonts")
	testing.expect(t, !has_switch)

	ui.access_begin(&tree)
	focus = ui.dropdown_access(&d, c, ANCHOR, &tree, 0, ID, "Font", "B", true, 1)
	testing.expect_value(t, ui.access_commit(&tree, &p, window, focus), platform.Error.None)
	font_switch, found := named(tree.nodes[:], "Show all fonts")
	if !testing.expect(t, found) {return}
	testing.expect_value(t, focus, font_switch.id)
}

// The open bar is a Group of its controls where find_layout puts them, with the query's text, the toggles'
// states and the count as a live Status; invoking Next gives what clicking it gives, and the arrows are
// disabled and inert without matches.
@(test)
find_access_describes_the_bar_and_routes_its_buttons_as_clicks :: proc(t: ^testing.T) {
	text: ui.Text
	fonts, ok := text_open(t, &text)
	if !ok {return}
	defer font.system_destroy(fonts)
	f: ui.Find_Bar
	ui.find_init(&f)
	defer ui.find_destroy(&f)
	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)
	ui.find_open(&f)
	ui.find_text(&f, "needle")
	f.options.case_sensitive = true
	status :: "3 of 17"
	detail := ui.text_styled(&text, .Detail)
	l := ui.find_layout(1000, 1, ui.text_width(&detail, status))

	ui.find_access(&f, &tree, &text, PARENT, ID, "Find in terminal", status, true, 1000, 1)
	nodes := tree.nodes[:]
	expected := [?]struct {
		role:    platform.Access_Role,
		name:    string,
		rect:    render.Rect,
		checked: bool,
	} {
		{.Text_Field, "Find", l.query, false},
		{.Check_Box, "Match case", l.case_toggle, true},
		{.Check_Box, "Regular expression", l.regex_toggle, false},
		{.Status, status, l.status, false},
		{.Button, "Previous match", l.up, false},
		{.Button, "Next match", l.down, false},
		{.Button, "Close", l.close, false},
	}
	if !testing.expect_value(t, len(nodes), 1 + len(expected)) {return}
	expect_tree(t, nodes, PARENT)
	group := nodes[0]
	testing.expect_value(t, group.role, platform.Access_Role.Group)
	testing.expect_value(t, group.name, "Find in terminal")
	testing.expect_value(t, group.bounds, rect_bounds(l.panel))
	for want, i in expected {
		node := nodes[1 + i]
		testing.expect_value(t, node.parent, group.id)
		testing.expect_value(t, node.role, want.role)
		testing.expect_value(t, node.name, want.name)
		testing.expect_value(t, node.bounds, rect_bounds(want.rect))
		testing.expect_value(t, .Checked in node.states, want.checked)
		testing.expect(t, .Disabled not_in node.states)
	}
	query := nodes[1]
	testing.expect_value(t, query.id, ID)
	testing.expect_value(t, query.value, "needle")
	testing.expect(t, .Focusable in query.states)

	next, _ := named(nodes, "Next match")
	close, _ := named(nodes, "Close")
	x, y := center(next)
	ui.find_mouse(&f, l, true, .Left, true, x, y)
	clicked := ui.find_mouse(&f, l, true, .Left, false, x, y)
	testing.expect_value(t, clicked, ui.Find_Outcome(search.Step.Down))
	ui.find_blur(&f)
	testing.expect_value(t, ui.find_access_invoke(&f, ID, {id = next.id, action = .Invoke}, true), clicked)
	testing.expect(t, ui.find_has_keyboard(&f))

	match_case, _ := named(nodes, "Match case")
	testing.expect_value(
		t,
		ui.find_access_invoke(&f, ID, {id = match_case.id, action = .Invoke}, true),
		ui.Find_Outcome(ui.Find_Change.None),
	)
	testing.expect_value(
		t,
		ui.find_access_invoke(&f, ID, {id = match_case.id, action = .Toggle}, true),
		ui.Find_Outcome(ui.Find_Change.Changed),
	)
	testing.expect(t, !f.options.case_sensitive)

	ui.access_begin(&tree)
	ui.find_access(&f, &tree, &text, PARENT, ID, "Find in terminal", "", false, 1000, 1)
	for node in tree.nodes {
		testing.expect(t, node.role != .Status)
		arrow := node.name == "Previous match" || node.name == "Next match"
		testing.expect_value(t, .Disabled in node.states, arrow)
	}
	testing.expect_value(
		t,
		ui.find_access_invoke(&f, ID, {id = next.id, action = .Invoke}, false),
		ui.Find_Outcome(ui.Find_Change.None),
	)
	testing.expect_value(
		t,
		ui.find_access_invoke(&f, ID, {id = close.id, action = .Invoke}, true),
		ui.Find_Outcome(ui.Find_Change.Closed),
	)

	ui.find_close(&f)
	ui.access_begin(&tree)
	ui.find_access(&f, &tree, &text, PARENT, ID, "Find in terminal", status, true, 1000, 1)
	testing.expect_value(t, len(tree.nodes), 0)
}

@(test)
find_access_commits_query_focus_even_when_the_field_has_no_width :: proc(t: ^testing.T) {
	p: platform.Platform
	window, ok := access_window_open(t, &p, "Find")
	defer testing.expect_value(t, platform.destroy(&p), platform.Error.None)
	if !ok {return}
	text: ui.Text
	fonts, text_ok := text_open(t, &text)
	if !text_ok {return}
	defer font.system_destroy(fonts)
	f: ui.Find_Bar
	ui.find_init(&f)
	defer ui.find_destroy(&f)
	ui.find_open(&f)
	ui.find_text(&f, "needle")
	testing.expect(t, ui.find_has_keyboard(&f))
	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)

	for width in ([?]f32{80, 24}) {
		ui.access_begin(&tree)
		ui.find_access(&f, &tree, &text, 0, ID, "Find in terminal", "", false, width, 1)
		testing.expect_value(t, ui.access_commit(&tree, &p, window, ID), platform.Error.None)
		query, found := named(tree.nodes[:], "Find")
		if !testing.expect(t, found) {continue}
		testing.expect_value(t, query.id, ID)
		testing.expect_value(t, query.role, platform.Access_Role.Text_Field)
		testing.expect_value(t, query.value, "needle")
		testing.expect_value(t, query.bounds[2], 0)
		testing.expect(t, .Focusable in query.states)
	}
}

@(private = "file")
notices_fill :: proc(n: ^ui.Notices, now: time.Tick) {
	ui.notices_put(n, 0, .Info, "first", time.Hour, false, now)
	ui.notices_put(n, 0, .Warning, "second", time.Hour, false, now)
	ui.notices_put(n, 0, .Error, "third", time.Hour, false, now)
	ui.notices_put(n, 42, .Success, "Saved", time.Hour, false, now, "Undo", "Ctrl+Z")
}

// Each card the closed deck shows is a Status named by its text on the card; the front card holds its Undo
// and Dismiss buttons where a press lands on them, and invoking Undo acts as clicking it does.
@(test)
notices_access_describes_shown_cards_and_acts_as_their_buttons :: proc(t: ^testing.T) {
	text: ui.Text
	fonts, ok := text_open(t, &text)
	if !ok {return}
	defer font.system_destroy(fonts)
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)
	now := time.tick_now()
	notices_fill(&n, now)

	ui.notices_access(&n, &tree, &text, PARENT, ID, 1000, 800, 1)
	nodes := tree.nodes[:]
	expect_tree(t, nodes, PARENT)
	live := ui.notices_live(&n)
	// Two cards peek out behind the front one; the oldest is hidden behind them.
	statuses := 0
	for node in nodes {
		if node.role != .Status {continue}
		item := live[1 + statuses]
		testing.expect_value(t, node.name, item.text)
		testing.expect_value(t, node.id, ui.access_part(ID, item.id))
		testing.expect_value(t, node.parent, PARENT)
		testing.expect_value(t, node.bounds, rect_bounds(item.card.box))
		statuses += 1
	}
	testing.expect_value(t, statuses, 3)
	front := live[3]
	undo, has_undo := named(nodes, "Undo")
	dismiss, has_dismiss := named(nodes, "Dismiss")
	if !testing.expect(t, has_undo && has_dismiss) {return}
	for button in ([?]platform.Access_Node{undo, dismiss}) {
		testing.expect_value(t, button.role, platform.Access_Role.Button)
		testing.expect_value(t, button.parent, ui.access_part(ID, front.id))
	}
	testing.expect_value(t, undo.bounds, rect_bounds(ui.notices_action_rect(&n, &text, 1000, 800, 1, front.id)))
	x, y := center(dismiss)
	hit := ui.notices_hit(&n, &text, 1000, 800, 1, x, y)
	testing.expect(t, hit.close && hit.id == front.id)
	x, y = center(undo)
	hit = ui.notices_hit(&n, &text, 1000, 800, 1, x, y)
	testing.expect(t, hit.action && hit.id == front.id)

	// The same deck clicked: a press and release on Undo.
	clicked: ui.Notices
	ui.notices_init(&clicked)
	defer ui.notices_destroy(&clicked)
	notices_fill(&clicked, now)
	button := ui.notice_hit_button(ui.notices_hit(&clicked, &text, 1000, 800, 1, x, y))
	ui.notices_press(&clicked, button)
	click_dismissed, click_acted := ui.notices_release(&clicked, button, false)
	testing.expect(t, click_dismissed)
	testing.expect_value(t, click_acted, 42)

	invoke := platform.Access_Invoke_Event{id = undo.id, action = .Invoke}
	dismissed, acted := ui.notices_access_invoke(&n, ID, invoke, false)
	testing.expect_value(t, dismissed, click_dismissed)
	testing.expect_value(t, acted, click_acted)
	testing.expect(t, !ui.notices_showing(&n, 42))
	dismissed, acted = ui.notices_access_invoke(&n, ID, invoke, false)
	testing.expect(t, !dismissed && acted == 0)
}

// A field's node carries its text, never its hint, and sits where the field draws; a text area's carries
// every line and says when it is read-only.
@(test)
field_and_text_area_access_carry_their_text :: proc(t: ^testing.T) {
	tree: ui.Access_Tree
	ui.access_init(&tree)
	defer ui.access_destroy(&tree)
	field: ui.Text_Field
	defer delete(field.bytes)
	rect := render.Rect{20, 30, 200, 24}

	ui.field_access(&field, &tree, PARENT, ID, "Name", rect)
	ui.field_set(&field, "Ada")
	ui.field_access(&field, &tree, PARENT, ID + 1, "Name", rect)
	if !testing.expect_value(t, len(tree.nodes), 2) {return}
	for node, i in tree.nodes {
		testing.expect_value(t, node.role, platform.Access_Role.Text_Field)
		testing.expect_value(t, node.name, "Name")
		testing.expect_value(t, node.value, i == 0 ? "" : "Ada")
		testing.expect_value(t, node.bounds, rect_bounds(rect))
		testing.expect_value(t, node.states, bit_set[platform.Access_State;u16]{.Focusable})
	}

	// The value is the buffer's, so no font lays the text out.
	text: ui.Text
	buffer: textedit.Buffer
	if !testing.expect(t, textedit.init(&buffer, "first line\nsecond line")) {return}
	defer textedit.destroy(&buffer)
	area: ui.Text_Area
	defer ui.text_area_destroy(&area)
	box := ui.Text_Area_Box{area = &area, buffer = &buffer, text = &text, rect = {10, 60, 300, 80}, scale = 1}
	ui.access_begin(&tree)
	ui.text_area_access(box, &tree, PARENT, ID, "Comment", true)
	ui.text_area_access(box, &tree, PARENT, ID + 1, "Comment", false)
	if !testing.expect_value(t, len(tree.nodes), 2) {return}
	testing.expect_value(t, tree.nodes[0].value, "first line\nsecond line")
	testing.expect_value(t, tree.nodes[0].bounds, rect_bounds(box.rect))
	testing.expect_value(t, tree.nodes[0].states, bit_set[platform.Access_State;u16]{.Focusable, .Read_Only})
	testing.expect_value(t, tree.nodes[1].states, bit_set[platform.Access_State;u16]{.Focusable})
}
