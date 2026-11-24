package platform_headless_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "cosmos:input"
import "cosmos:platform"

@(private = "file")
open :: proc(t: ^testing.T, p: ^platform.Platform, name: string) -> (input.Window_Id, bool) {
	id := fmt.tprintf("AIODev.Test.Headless.Access.%s.%d", name, os.get_pid())
	if !testing.expect_value(t, platform.init(p, id), platform.Init_Result.Primary) {return 0, false}
	window, err := platform.window_create(p, {title = "Access", width = 400, height = 300, hidden = true})
	return window, testing.expect_value(t, err, platform.Error.None)
}

// The stored tree is a copy: the app builds names in per-frame memory and frees them after the set.
@(test)
access_tree_is_stored_as_a_copy :: proc(t: ^testing.T) {
	p: platform.Platform
	window, ok := open(t, &p, "Copy")
	defer _ = platform.destroy(&p)
	if !ok {return}
	save := strings.clone("Save")
	search := strings.clone("Search")
	query := strings.clone("needle")
	nodes := []platform.Access_Node {
		{id = 1, role = .Group, name = "Toolbar", bounds = {0, 0, 400, 40}},
		{id = 2, parent = 1, role = .Button, name = save, bounds = {8, 4, 80, 32}, states = {.Focusable}},
		{
			id = 3,
			role = .Text_Field,
			name = search,
			value = query,
			bounds = {8, 60, 200, 24},
			states = {.Focusable, .Read_Only},
		},
	}
	expected := make([]platform.Access_Node, len(nodes))
	defer delete(expected)
	copy(expected, nodes)
	expected[1].name, expected[2].name, expected[2].value = "Save", "Search", "needle"
	testing.expect_value(t, platform.window_access_set(&p, window, nodes, 2), platform.Error.None)
	for s in ([]string{save, search, query}) {
		bytes := transmute([]u8)s
		for &b in bytes {b = 'x'}
		delete(s)
	}

	stored, focus, err := platform.window_access(&p, window)
	testing.expect_value(t, err, platform.Error.None)
	testing.expect_value(t, focus, platform.Access_Id(2))
	if testing.expect_value(t, len(stored), len(expected)) {
		for node, i in stored {
			testing.expect_value(t, node.id, expected[i].id)
			testing.expect_value(t, node.parent, expected[i].parent)
			testing.expect_value(t, node.role, expected[i].role)
			testing.expect_value(t, node.name, expected[i].name)
			testing.expect_value(t, node.value, expected[i].value)
			testing.expect_value(t, node.bounds, expected[i].bounds)
			testing.expect_value(t, node.states, expected[i].states)
		}
	}

	// A smaller tree replaces the whole of the previous one.
	testing.expect_value(t, platform.window_access_set(&p, window, expected[:1], 0), platform.Error.None)
	stored, focus, _ = platform.window_access(&p, window)
	testing.expect_value(t, len(stored), 1)
	testing.expect_value(t, focus, platform.Access_Id(0))
}

// A tree that is not one is refused, and the tree held before stays.
@(test)
access_tree_must_be_well_formed :: proc(t: ^testing.T) {
	p: platform.Platform
	window, ok := open(t, &p, "Invalid")
	defer _ = platform.destroy(&p)
	if !ok {return}
	good := []platform.Access_Node{{id = 1, role = .Pane}, {id = 2, parent = 1, role = .Button, name = "OK"}}
	testing.expect_value(t, platform.window_access_set(&p, window, good, 2), platform.Error.None)
	bad := [][]platform.Access_Node {
		{{id = 0, role = .Button}},
		{{id = 1, role = .Pane}, {id = 1, role = .Button}},
		{{id = 2, parent = 1, role = .Button}, {id = 1, role = .Pane}},
		{{id = 1, parent = 1, role = .Pane}},
	}
	for nodes in bad {
		testing.expect_value(t, platform.window_access_set(&p, window, nodes, 0), platform.Error.Invalid_Argument)
	}
	testing.expect_value(t, platform.window_access_set(&p, window, good, 7), platform.Error.Invalid_Argument)
	stored, focus, _ := platform.window_access(&p, window)
	testing.expect_value(t, len(stored), 2)
	testing.expect_value(t, focus, platform.Access_Id(2))
	testing.expect_value(t, platform.window_access_set(&p, 99, good, 0), platform.Error.Invalid_Window)
}

// What an assistive technology asks reaches the app as events, in order, naming window and node.
@(test)
access_requests_arrive_as_events :: proc(t: ^testing.T) {
	p: platform.Platform
	window, ok := open(t, &p, "Events")
	defer _ = platform.destroy(&p)
	if !ok {return}
	nodes := []platform.Access_Node {
		{id = 4, role = .Button, name = "Run"},
		{id = 5, role = .Check_Box, name = "Wrap"},
		{id = 6, role = .Combo_Box, name = "Theme", states = {.Collapsed}},
	}
	testing.expect_value(t, platform.window_access_set(&p, window, nodes, 0), platform.Error.None)
	_, _ = platform.poll_events(&p)
	testing.expect_value(t, platform.access_invoke(&p, window, 4, .Invoke), platform.Error.None)
	testing.expect_value(t, platform.access_invoke(&p, window, 5, .Toggle), platform.Error.None)
	testing.expect_value(t, platform.access_invoke(&p, window, 6, .Expand), platform.Error.None)
	testing.expect_value(t, platform.access_focus(&p, window, 5), platform.Error.None)
	testing.expect_value(t, platform.access_invoke(&p, window, 9, .Invoke), platform.Error.Invalid_Argument)
	events, err := platform.poll_events(&p)
	testing.expect_value(t, err, platform.Error.None)
	invokes := make([dynamic]platform.Access_Invoke_Event, context.temp_allocator)
	focuses := make([dynamic]platform.Access_Focus_Event, context.temp_allocator)
	for event in events {
		#partial switch e in event {
		case platform.Access_Invoke_Event:
			append(&invokes, e)
		case platform.Access_Focus_Event:
			append(&focuses, e)
		}
	}
	expected := []platform.Access_Invoke_Event{{window, 4, .Invoke}, {window, 5, .Toggle}, {window, 6, .Expand}}
	if testing.expect_value(t, len(invokes), len(expected)) {
		for e, i in invokes {testing.expect_value(t, e, expected[i])}
	}
	if testing.expect_value(t, len(focuses), 1) {
		testing.expect_value(t, focuses[0], platform.Access_Focus_Event{window, 5})
	}
}
