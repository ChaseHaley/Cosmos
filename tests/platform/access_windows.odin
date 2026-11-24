package platform_test

import p "cosmos:platform"
import "core:strconv"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import w "core:sys/windows"
import "core:unicode/utf16"

// The provider is driven through the UI Automation client API, as a screen reader drives it. The client
// runs on its own thread while the test thread, the window's STA, pumps messages: UI Automation marshals
// every provider call to that thread, so a client on it would wait on itself. core:sys/windows has no
// UI Automation client interfaces, so the few used are declared here, with the slots before and between
// them kept as padding in the order UIAutomationClient.h gives.

foreign import access_oleaut32 "system:oleaut32.lib"

@(private = "file", default_calling_convention = "system")
foreign access_oleaut32 {
	SysAllocString :: proc(text: cstring16) -> [^]u16 ---
	SysFreeString :: proc(text: [^]u16) ---
	SysStringLen :: proc(text: [^]u16) -> u32 ---
}

@(private = "file")
CLSID_CUIAutomation := w.GUID{0xff48dba4, 0x60ef, 0x4201, {0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e}}
@(private = "file")
IID_IUIAutomation := w.GUID{0x30cbe57d, 0xd9d0, 0x452a, {0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee}}
@(private = "file")
IID_Invoke_Pattern := w.GUID{0xfb377fbe, 0x8ea6, 0x46d5, {0x9c, 0x73, 0x64, 0x99, 0x64, 0x2d, 0x30, 0x59}}
@(private = "file")
IID_Toggle_Pattern := w.GUID{0x94cf8058, 0x9b8d, 0x4ab9, {0x8b, 0xfd, 0x4c, 0xd0, 0xa3, 0x3c, 0x8c, 0x70}}
@(private = "file")
IID_Expand_Collapse_Pattern := w.GUID {
	0x619be086, 0x1f4e, 0x4ee4, {0xba, 0xfa, 0x21, 0x01, 0x28, 0x73, 0x87, 0x30},
}
@(private = "file")
IID_Value_Pattern := w.GUID{0xa94cd8b1, 0x0844, 0x4cd6, {0x9d, 0x2d, 0x64, 0x05, 0x37, 0xab, 0x39, 0xe9}}

@(private = "file")
UIA_INVOKE_PATTERN :: 10000
@(private = "file")
UIA_VALUE_PATTERN :: 10002
@(private = "file")
UIA_EXPAND_COLLAPSE_PATTERN :: 10005
@(private = "file")
UIA_TOGGLE_PATTERN :: 10015
@(private = "file")
UIA_BUTTON :: 50000
@(private = "file")
UIA_CHECK_BOX :: 50002
@(private = "file")
UIA_COMBO_BOX :: 50003
@(private = "file")
UIA_EDIT :: 50004
@(private = "file")
UIA_TEXT :: 50020
@(private = "file")
UIA_GROUP :: 50026
@(private = "file")
UIA_WINDOW :: 50032
@(private = "file")
UIA_E_ELEMENTNOTAVAILABLE :: 0x80040201
@(private = "file")
TOGGLE_STATE_ON :: 1
@(private = "file")
EXPAND_COLLAPSE_STATE_COLLAPSED :: 0

@(private = "file")
Automation :: struct #raw_union {
	#subtype iunknown: w.IUnknown,
	using vtable: ^Automation_VTable,
}
@(private = "file")
Automation_VTable :: struct {
	using unknown:     w.IUnknown_VTable,
	// CompareElements, CompareRuntimeIds, GetRootElement
	_:                 [3]rawptr,
	ElementFromHandle: proc "system" (this: ^Automation, window: w.HWND, element: ^^Element) -> w.HRESULT,
	// ElementFromPoint through get_ContentViewWalker
	_:                 [9]rawptr,
	get_RawViewWalker: proc "system" (this: ^Automation, walker: ^^Tree_Walker) -> w.HRESULT,
}

@(private = "file")
Element :: struct #raw_union {
	#subtype iunknown: w.IUnknown,
	using vtable: ^Element_VTable,
}
@(private = "file")
Element_VTable :: struct {
	using unknown:                  w.IUnknown_VTable,
	// SetFocus through GetCachedPropertyValueEx
	_:                              [11]rawptr,
	GetCurrentPatternAs:            proc "system" (
		this: ^Element,
		pattern: i32,
		riid: ^w.GUID,
		out: ^rawptr,
	) -> w.HRESULT,
	// GetCachedPatternAs through get_CurrentProcessId
	_:                              [6]rawptr,
	get_CurrentControlType:         proc "system" (this: ^Element, out: ^i32) -> w.HRESULT,
	// get_CurrentLocalizedControlType
	_:                              [1]rawptr,
	get_CurrentName:                proc "system" (this: ^Element, out: ^[^]u16) -> w.HRESULT,
	// get_CurrentAcceleratorKey, get_CurrentAccessKey
	_:                              [2]rawptr,
	get_CurrentHasKeyboardFocus:    proc "system" (this: ^Element, out: ^w.BOOL) -> w.HRESULT,
	get_CurrentIsKeyboardFocusable: proc "system" (this: ^Element, out: ^w.BOOL) -> w.HRESULT,
	get_CurrentIsEnabled:           proc "system" (this: ^Element, out: ^w.BOOL) -> w.HRESULT,
	get_CurrentAutomationId:        proc "system" (this: ^Element, out: ^[^]u16) -> w.HRESULT,
	// get_CurrentClassName through get_CurrentItemType
	_:                              [8]rawptr,
	get_CurrentIsOffscreen:         proc "system" (this: ^Element, out: ^w.BOOL) -> w.HRESULT,
	// get_CurrentOrientation through get_CurrentItemStatus
	_:                              [4]rawptr,
	get_CurrentBoundingRectangle:   proc "system" (this: ^Element, out: ^w.RECT) -> w.HRESULT,
}

@(private = "file")
Tree_Walker :: struct #raw_union {
	#subtype iunknown: w.IUnknown,
	using vtable: ^Tree_Walker_VTable,
}
@(private = "file")
Tree_Walker_VTable :: struct {
	using unknown:         w.IUnknown_VTable,
	// GetParentElement
	_:                     [1]rawptr,
	GetFirstChildElement:  proc "system" (this: ^Tree_Walker, element: ^Element, first: ^^Element) -> w.HRESULT,
	// GetLastChildElement
	_:                     [1]rawptr,
	GetNextSiblingElement: proc "system" (this: ^Tree_Walker, element: ^Element, next: ^^Element) -> w.HRESULT,
}

@(private = "file")
Invoke_Pattern :: struct #raw_union {
	#subtype iunknown: w.IUnknown,
	using vtable: ^struct {
		using unknown: w.IUnknown_VTable,
		Invoke:        proc "system" (this: ^Invoke_Pattern) -> w.HRESULT,
	},
}

@(private = "file")
Toggle_Pattern :: struct #raw_union {
	#subtype iunknown: w.IUnknown,
	using vtable: ^struct {
		using unknown:          w.IUnknown_VTable,
		Toggle:                 proc "system" (this: ^Toggle_Pattern) -> w.HRESULT,
		get_CurrentToggleState: proc "system" (this: ^Toggle_Pattern, out: ^i32) -> w.HRESULT,
	},
}

@(private = "file")
Expand_Collapse_Pattern :: struct #raw_union {
	#subtype iunknown: w.IUnknown,
	using vtable: ^struct {
		using unknown:                  w.IUnknown_VTable,
		Expand:                         proc "system" (this: ^Expand_Collapse_Pattern) -> w.HRESULT,
		Collapse:                       proc "system" (this: ^Expand_Collapse_Pattern) -> w.HRESULT,
		get_CurrentExpandCollapseState: proc "system" (this: ^Expand_Collapse_Pattern, out: ^i32) -> w.HRESULT,
	},
}

@(private = "file")
Value_Pattern :: struct #raw_union {
	#subtype iunknown: w.IUnknown,
	using vtable: ^struct {
		using unknown:         w.IUnknown_VTable,
		SetValue:              proc "system" (this: ^Value_Pattern, value: [^]u16) -> w.HRESULT,
		get_CurrentValue:      proc "system" (this: ^Value_Pattern, out: ^[^]u16) -> w.HRESULT,
		get_CurrentIsReadOnly: proc "system" (this: ^Value_Pattern, out: ^w.BOOL) -> w.HRESULT,
	},
}

@(private = "file")
release :: proc "contextless" (object: rawptr) {
	if object != nil {
		unknown := (^w.IUnknown)(object)
		unknown->Release()
	}
}

// Where the client is. The test thread changes the tree at Changing and destroys the window at Closing.
@(private = "file")
Phase :: enum i32 {
	Reading,
	Changing,
	Changed,
	Closing,
	Closed,
	Done,
}

@(private = "file")
Text :: struct {
	bytes: [32]u8,
	len:   int,
}

@(private = "file")
text_string :: proc(text: ^Text) -> string {
	return string(text.bytes[:text.len])
}

// One of the app's nodes as the client found it, with the parent the walk reached it from.
@(private = "file")
Found :: struct {
	id, parent:                    u64,
	name:                          Text,
	control_type:                  i32,
	rect:                          w.RECT,
	focusable, focused, offscreen: bool,
}

@(private = "file")
Client :: struct {
	window:                 w.HWND,
	// A Phase, read and written by both threads.
	phase:                  i32,
	// The first client call that failed where it should not have.
	failed_call:            cstring,
	failed_result:          u32,
	timed_out:              bool,
	root_name:              Text,
	root_type:              i32,
	found:                  [8]Found,
	found_count:            int,
	toggle_state:           i32,
	expand_state:           i32,
	value:                  Text,
	read_only:              w.BOOL,
	invoke_result:          w.HRESULT,
	toggle_result:          w.HRESULT,
	expand_result:          w.HRESULT,
	set_value_result:       w.HRESULT,
	button_has_toggle:      bool,
	removed_name_result:    w.HRESULT,
	renamed:                Text,
	toolbar_children_after: int,
	destroyed_name_result:  w.HRESULT,
}

@(private = "file")
phase_get :: proc(client: ^Client) -> Phase {
	return Phase(sync.atomic_load(&client.phase))
}

@(private = "file")
phase_set :: proc(client: ^Client, phase: Phase) {
	sync.atomic_store(&client.phase, i32(phase))
}

@(private = "file")
check :: proc(client: ^Client, result: w.HRESULT, call: cstring) -> bool {
	if result >= 0 {return true}
	if client.failed_call == nil {client.failed_call, client.failed_result = call, u32(result)}
	return false
}

@(private = "file")
take_text :: proc(text: [^]u16, out: ^Text) {
	out.len = 0
	if text == nil {return}
	out.len = utf16.decode_to_utf8(out.bytes[:], text[:SysStringLen(text)])
	SysFreeString(text)
}

@(private = "file")
await_phase :: proc(client: ^Client, phase: Phase) -> bool {
	start := time.tick_now()
	for phase_get(client) != phase {
		if time.tick_since(start) > 10 * time.Second {
			client.timed_out = true
			return false
		}
		time.sleep(time.Millisecond)
	}
	return true
}

@(private = "file")
child_count :: proc(walker: ^Tree_Walker, parent: ^Element) -> int {
	count := 0
	child: ^Element
	if walker->GetFirstChildElement(parent, &child) < 0 {return -1}
	for child != nil {
		count += 1
		next: ^Element
		result := walker->GetNextSiblingElement(child, &next)
		release(child)
		if result < 0 {return -1}
		child = next
	}
	return count
}

// Records the app's nodes under `parent` in reading order and keeps each one's element in `held`.
// Other children, such as the title bar the window's own provider adds, have no numeric AutomationId.
@(private = "file")
walk :: proc(client: ^Client, walker: ^Tree_Walker, parent: ^Element, parent_id: u64, held: ^[8]^Element) {
	child: ^Element
	if !check(client, walker->GetFirstChildElement(parent, &child), "GetFirstChildElement") {return}
	for child != nil {
		id_text: Text
		automation_id: [^]u16
		if check(client, child->get_CurrentAutomationId(&automation_id), "get_CurrentAutomationId") {
			take_text(automation_id, &id_text)
		}
		id, numeric := strconv.parse_u64(text_string(&id_text))
		if numeric && id > 0 && id < u64(len(held^)) && client.found_count < len(client.found) {
			found := &client.found[client.found_count]
			client.found_count += 1
			found.id, found.parent = id, parent_id
			name: [^]u16
			if check(client, child->get_CurrentName(&name), "get_CurrentName") {take_text(name, &found.name)}
			check(client, child->get_CurrentControlType(&found.control_type), "get_CurrentControlType")
			check(client, child->get_CurrentBoundingRectangle(&found.rect), "get_CurrentBoundingRectangle")
			flag: w.BOOL
			check(client, child->get_CurrentIsKeyboardFocusable(&flag), "get_CurrentIsKeyboardFocusable")
			found.focusable = bool(flag)
			check(client, child->get_CurrentHasKeyboardFocus(&flag), "get_CurrentHasKeyboardFocus")
			found.focused = bool(flag)
			check(client, child->get_CurrentIsOffscreen(&flag), "get_CurrentIsOffscreen")
			found.offscreen = bool(flag)
			walk(client, walker, child, id, held)
			held[id] = child
			child->AddRef()
		}
		next: ^Element
		result := walker->GetNextSiblingElement(child, &next)
		release(child)
		if !check(client, result, "GetNextSiblingElement") {return}
		child = next
	}
}

@(private = "file")
pattern :: proc(client: ^Client, element: ^Element, id: i32, iid: ^w.GUID, $T: typeid) -> ^T {
	if element == nil {return nil}
	out: rawptr
	if !check(client, element->GetCurrentPatternAs(id, iid, &out), "GetCurrentPatternAs") {return nil}
	return (^T)(out)
}

@(private = "file")
run_client :: proc(worker: ^thread.Thread) {
	client := (^Client)(worker.data)
	defer phase_set(client, .Done)
	if !check(client, w.CoInitializeEx(nil, .MULTITHREADED), "CoInitializeEx") {return}
	defer w.CoUninitialize()
	automation: ^Automation
	if !check(
		client,
		w.CoCreateInstance(
			&CLSID_CUIAutomation,
			nil,
			w.CLSCTX_INPROC_SERVER,
			&IID_IUIAutomation,
			cast(^rawptr)&automation,
		),
		"CoCreateInstance(CUIAutomation)",
	) {return}
	defer release(automation)
	root: ^Element
	if !check(client, automation->ElementFromHandle(client.window, &root), "ElementFromHandle") {return}
	defer release(root)
	walker: ^Tree_Walker
	if !check(client, automation->get_RawViewWalker(&walker), "get_RawViewWalker") {return}
	defer release(walker)

	root_name: [^]u16
	if check(client, root->get_CurrentName(&root_name), "get_CurrentName(root)") {
		take_text(root_name, &client.root_name)
	}
	check(client, root->get_CurrentControlType(&client.root_type), "get_CurrentControlType(root)")
	held: [8]^Element
	defer {
		for element in held {release(element)}
	}
	walk(client, walker, root, 0, &held)

	invoke := pattern(client, held[2], UIA_INVOKE_PATTERN, &IID_Invoke_Pattern, Invoke_Pattern)
	if invoke != nil {
		client.invoke_result = invoke->Invoke()
		release(invoke)
	}
	if held[2] != nil {
		out: rawptr
		check(client, held[2]->GetCurrentPatternAs(UIA_TOGGLE_PATTERN, &IID_Toggle_Pattern, &out), "button toggle")
		client.button_has_toggle = out != nil
		release(out)
	}
	toggle := pattern(client, held[3], UIA_TOGGLE_PATTERN, &IID_Toggle_Pattern, Toggle_Pattern)
	if toggle != nil {
		check(client, toggle->get_CurrentToggleState(&client.toggle_state), "get_CurrentToggleState")
		client.toggle_result = toggle->Toggle()
		release(toggle)
	}
	value := pattern(client, held[4], UIA_VALUE_PATTERN, &IID_Value_Pattern, Value_Pattern)
	if value != nil {
		text: [^]u16
		if check(client, value->get_CurrentValue(&text), "get_CurrentValue") {take_text(text, &client.value)}
		check(client, value->get_CurrentIsReadOnly(&client.read_only), "get_CurrentIsReadOnly")
		replacement := SysAllocString(w.L("typed"))
		client.set_value_result = value->SetValue(replacement)
		SysFreeString(replacement)
		release(value)
	}
	expand := pattern(
		client,
		held[5],
		UIA_EXPAND_COLLAPSE_PATTERN,
		&IID_Expand_Collapse_Pattern,
		Expand_Collapse_Pattern,
	)
	if expand != nil {
		check(client, expand->get_CurrentExpandCollapseState(&client.expand_state), "get_ExpandCollapseState")
		client.expand_result = expand->Expand()
		release(expand)
	}

	phase_set(client, .Changing)
	if !await_phase(client, .Changed) {return}
	if held[3] != nil {
		name: [^]u16
		client.removed_name_result = held[3]->get_CurrentName(&name)
		if name != nil {SysFreeString(name)}
	}
	if held[2] != nil {
		name: [^]u16
		if check(client, held[2]->get_CurrentName(&name), "get_CurrentName(renamed)") {
			take_text(name, &client.renamed)
		}
	}
	if held[1] != nil {client.toolbar_children_after = child_count(walker, held[1])}

	phase_set(client, .Closing)
	if !await_phase(client, .Closed) {return}
	if held[2] != nil {
		name: [^]u16
		client.destroyed_name_result = held[2]->get_CurrentName(&name)
		if name != nil {SysFreeString(name)}
	}
}

@(test)
ui_automation_reads_and_drives_the_access_tree :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.Access"), p.Init_Result.Primary) {return}
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	id, err := p.window_create(&platform, {hidden = true, title = "Access", width = 400, height = 300})
	if !testing.expect_value(t, err, p.Error.None) {return}
	nodes := [?]p.Access_Node {
		{id = 1, role = .Group, name = "Toolbar", bounds = {0, 0, 400, 40}},
		{id = 2, parent = 1, role = .Button, name = "Save", bounds = {8, 4, 80, 32}, states = {.Focusable}},
		{
			id = 3,
			parent = 1,
			role = .Check_Box,
			name = "Wrap lines",
			bounds = {100, 4, 120, 32},
			states = {.Focusable, .Checked},
		},
		{
			id = 4,
			role = .Text_Field,
			name = "Search",
			value = "find me",
			bounds = {8, 60, 200, 24},
			states = {.Focusable},
		},
		{
			id = 5,
			role = .Combo_Box,
			name = "Theme",
			value = "Dark",
			bounds = {8, 100, 120, 24},
			states = {.Focusable, .Collapsed},
		},
		{id = 6, role = .Status, name = "Saved", bounds = {0, 280, 400, 20}},
	}
	if !testing.expect_value(t, p.window_access_set(&platform, id, nodes[:], 2), p.Error.None) {return}
	origin_x, origin_y, origin_error := p.window_to_screen(&platform, id, 0, 0)
	testing.expect_value(t, origin_error, p.Error.None)

	client := Client {
		window = w.HWND(p.window_native_handle(&platform, id)),
	}
	worker := thread.create(run_client)
	if !testing.expect(t, worker != nil) {return}
	worker.data = &client
	thread.start(worker)
	requests := make([dynamic]p.Access_Invoke_Event, context.temp_allocator)
	poll_failed := false
	start := time.tick_now()
	for phase_get(&client) != .Done && time.tick_since(start) < 30 * time.Second {
		events, poll_error := p.poll_events(&platform)
		poll_failed ||= poll_error != .None
		for event in events {
			if request, is_request := event.(p.Access_Invoke_Event); is_request {append(&requests, request)}
		}
		#partial switch phase_get(&client) {
		case .Changing:
			// The check box goes and the button is renamed, as a frame that changed them would set.
			changed := [?]p.Access_Node{nodes[0], nodes[1], nodes[3], nodes[4], nodes[5]}
			changed[1].name = "Save all"
			testing.expect_value(t, p.window_access_set(&platform, id, changed[:], 2), p.Error.None)
			phase_set(&client, .Changed)
		case .Closing:
			testing.expect_value(t, p.window_destroy(&platform, id), p.Error.None)
			phase_set(&client, .Closed)
		}
		_, _ = p.wait_events(&platform, 5, nil)
	}
	thread.join(worker)
	thread.destroy(worker)

	testing.expect(t, !poll_failed)
	testing.expect(t, !client.timed_out)
	failure := client.failed_call
	if !testing.expectf(t, failure == nil, "%s failed: 0x%x", failure, client.failed_result) {
		return
	}
	testing.expect_value(t, text_string(&client.root_name), "Access")
	testing.expect_value(t, client.root_type, i32(UIA_WINDOW))
	Expected :: struct {
		id, parent:   u64,
		name:         string,
		control_type: i32,
	}
	expected := [?]Expected {
		{1, 0, "Toolbar", UIA_GROUP},
		{2, 1, "Save", UIA_BUTTON},
		{3, 1, "Wrap lines", UIA_CHECK_BOX},
		{4, 0, "Search", UIA_EDIT},
		{5, 0, "Theme", UIA_COMBO_BOX},
		{6, 0, "Saved", UIA_TEXT},
	}
	if testing.expect_value(t, client.found_count, len(expected)) {
		for &found, i in client.found[:client.found_count] {
			want := expected[i]
			testing.expect_value(t, found.id, want.id)
			testing.expect_value(t, found.parent, want.parent)
			testing.expect_value(t, text_string(&found.name), want.name)
			testing.expect_value(t, found.control_type, want.control_type)
			b := nodes[i].bounds
			left, top := origin_x + i32(b[0]), origin_y + i32(b[1])
			testing.expect_value(t, found.rect, w.RECT{left, top, left + i32(b[2]), top + i32(b[3])})
			testing.expect_value(t, found.focusable, .Focusable in nodes[i].states)
			// The app's focus is node 2, but a hidden window has no keyboard focus to give it.
			testing.expect(t, !found.focused)
			testing.expect(t, found.offscreen)
		}
	}

	testing.expect_value(t, client.toggle_state, i32(TOGGLE_STATE_ON))
	testing.expect_value(t, client.expand_state, i32(EXPAND_COLLAPSE_STATE_COLLAPSED))
	testing.expect_value(t, text_string(&client.value), "find me")
	testing.expect(t, !bool(client.read_only))
	testing.expect(t, !client.button_has_toggle)
	testing.expect_value(t, client.invoke_result, w.HRESULT(0))
	testing.expect_value(t, client.toggle_result, w.HRESULT(0))
	testing.expect_value(t, client.expand_result, w.HRESULT(0))
	// Text is edited through the app's own keyboard handling; a value set from outside is refused.
	testing.expect(t, client.set_value_result < 0)
	wanted := [?]p.Access_Invoke_Event{{id, 2, .Invoke}, {id, 3, .Toggle}, {id, 5, .Expand}}
	if testing.expect_value(t, len(requests), len(wanted)) {
		for request, i in requests {testing.expect_value(t, request, wanted[i])}
	}

	testing.expect_value(t, u32(client.removed_name_result), u32(UIA_E_ELEMENTNOTAVAILABLE))
	testing.expect_value(t, text_string(&client.renamed), "Save all")
	testing.expect_value(t, client.toolbar_children_after, 1)
	// An element held past its window answers with an error rather than reading freed memory.
	testing.expect(t, client.destroyed_name_result < 0)
}
