package ui

import "cosmos:input"

// An app-chosen name for one focusable control, unique within its window. 0 is no control.
Focus_Id :: distinct u64

// A modal surface's share of the traversal while it is open; 0 is the window itself, which is always open.
Focus_Scope :: distinct u32

// Which control of a window has the keyboard, and the order Tab walks. The app owns one per window and
// registers its focusable controls each frame, in traversal order, between focus_frame_begin and
// focus_frame_end. Keys arrive before the next frame is built, so traversal walks the order of the last
// completed frame.
//
// `focused` and `changed` are for reading: `changed` says whether the last completed frame ended with a
// different control focused than the frame before it, which is when assistive technology hears of it.
Focus :: struct {
	focused:      Focus_Id,
	changed:      bool,
	// The ring shows: the last move of focus came from the keyboard, as the web's :focus-visible.
	visible:      bool,
	// What focus_frame_end last saw focused, so it can tell `changed`.
	reported:     Focus_Id,
	// The last completed frame's registrations, and the frame being built.
	order:        [dynamic]Focus_Entry,
	building:     [dynamic]Focus_Entry,
	// Open modal scopes, innermost last.
	scopes:       [dynamic]Focus_Scope_Entry,
	// Scopes never reuse a number, so a closed surface still drawing as it fades cannot register into
	// the scope that replaced it.
	scope_serial: Focus_Scope,
}

Focus_Entry :: struct {
	id:    Focus_Id,
	scope: Focus_Scope,
}

// An open scope and the control that had focus as it opened, which gets focus back when it closes.
Focus_Scope_Entry :: struct {
	scope:   Focus_Scope,
	restore: Focus_Id,
}

focus_init :: proc(f: ^Focus, allocator := context.allocator) {
	f.order = make([dynamic]Focus_Entry, allocator)
	f.building = make([dynamic]Focus_Entry, allocator)
	f.scopes = make([dynamic]Focus_Scope_Entry, allocator)
}

focus_destroy :: proc(f: ^Focus) {
	delete(f.order)
	delete(f.building)
	delete(f.scopes)
}

focus_frame_begin :: proc(f: ^Focus) {
	clear(&f.building)
}

// Registers the next control in traversal order, inside `scope` when a modal surface owns it.
focus_add :: proc(f: ^Focus, id: Focus_Id, scope := Focus_Scope(0)) {
	assert(id != 0)
	append(&f.building, Focus_Entry{id, scope})
}

// Completes the frame's order. A focused control the frame did not register in the innermost open scope
// is gone: focus moves to that scope's first control, so a modal surface keeps the keyboard, or to no
// control when no modal surface is open.
focus_frame_end :: proc(f: ^Focus) {
	f.order, f.building = f.building, f.order
	if f.focused != 0 {
		scope := focus_scope_top(f)
		first, found := Focus_Id(0), false
		for entry in f.order {
			if entry.scope != scope {continue}
			if first == 0 {first = entry.id}
			if entry.id == f.focused {found = true; break}
		}
		if !found {f.focused = scope == 0 ? 0 : first}
	}
	f.changed = f.focused != f.reported
	f.reported = f.focused
}

// Focuses `id` directly, as a pointer press or the app does. `visible` is whether the ring shows: false
// for a pointer press, true when a key moved focus.
focus_set :: proc(f: ^Focus, id: Focus_Id, visible: bool) {
	f.focused, f.visible = id, visible
}

// Moves to the next control in the innermost open scope, or the previous one, wrapping at the ends. With
// nothing focused there, forward starts at the first control and backward at the last. Returns false when
// the scope registered nothing in the last completed frame.
focus_move :: proc(f: ^Focus, backward: bool) -> bool {
	scope := focus_scope_top(f)
	count, at := 0, -1
	for entry in f.order {
		if entry.scope != scope {continue}
		if entry.id == f.focused {at = count}
		count += 1
	}
	if count == 0 {return false}
	target := backward ? count - 1 : 0
	if at >= 0 {target = (at + (backward ? count - 1 : 1)) % count}
	for entry in f.order {
		if entry.scope != scope {continue}
		if target == 0 {f.focused = entry.id; break}
		target -= 1
	}
	f.visible = true
	return true
}

// Tab and Shift+Tab move focus. Chords with Ctrl, Alt or the Windows key stay with the app and the system,
// as Ctrl+Tab switches the app's tabs. Returns whether the key moved focus.
focus_key :: proc(f: ^Focus, e: input.Key_Event) -> bool {
	chords :: input.Modifiers{.Control, .Alt, .Super, .Right_Control, .Right_Alt, .Right_Super}
	if !e.pressed || e.key != .Tab || e.modifiers & chords != {} {return false}
	return focus_move(f, .Shift in e.modifiers)
}

// Whether `id` draws the focus ring.
focus_visible :: proc(f: Focus, id: Focus_Id) -> bool {
	return f.visible && id != 0 && f.focused == id
}

// Restricts traversal to the controls registered in the returned scope until focus_scope_close. Focus
// stays where it is; the surface sets its own first focus.
focus_scope_open :: proc(f: ^Focus) -> Focus_Scope {
	f.scope_serial += 1
	append(&f.scopes, Focus_Scope_Entry{f.scope_serial, f.focused})
	return f.scope_serial
}

// Closes the innermost scope, which must be `scope`, and gives focus back to the control that had it as
// the scope opened. The ring keeps following the input that closed the surface.
focus_scope_close :: proc(f: ^Focus, scope: Focus_Scope) {
	assert(len(f.scopes) > 0 && f.scopes[len(f.scopes) - 1].scope == scope)
	f.focused = pop(&f.scopes).restore
}

@(private)
focus_scope_top :: proc(f: ^Focus) -> Focus_Scope {
	return len(f.scopes) == 0 ? 0 : f.scopes[len(f.scopes) - 1].scope
}
