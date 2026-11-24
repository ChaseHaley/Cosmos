package ui

import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"

// A window's semantic tree for one frame, filled while the frame is built: each widget adds the nodes of
// what it draws, parents before children. Names and values are borrowed until access_commit, which copies
// them to the platform.
//
// A focusable control's access id is its Focus_Id, so the app gives a control the same number for both
// and focus reaches assistive technology without a mapping.
Access_Tree :: struct {
	nodes: [dynamic]platform.Access_Node,
}

access_init :: proc(t: ^Access_Tree, allocator := context.allocator) {
	t.nodes = make([dynamic]platform.Access_Node, allocator)
}

access_destroy :: proc(t: ^Access_Tree) {
	delete(t.nodes)
	t^ = {}
}

access_begin :: proc(t: ^Access_Tree) {
	clear(&t.nodes)
}

// A node that fails to append is left out; a child that then names it as parent makes access_commit fail,
// so a short tree is reported rather than served.
access_add :: proc(t: ^Access_Tree, node: platform.Access_Node) {
	append(&t.nodes, node)
}

@(require_results)
access_commit :: proc(
	t: ^Access_Tree,
	p: ^platform.Platform,
	window: input.Window_Id,
	focus: platform.Access_Id,
) -> platform.Error {
	return platform.window_access_set(p, window, t.nodes[:], focus)
}

// The id of part `part` of a widget whose id is `base`, so a widget derives its rows' ids from the one id
// the app gives it. Both are hashed (splitmix64's finalizer, a bijection, around a sum), which spreads them
// over 64 bits: two distinct (base, part) pairs, or a part and an app's own small ids, collide with odds
// near 2^-64 per pair. Never 0, the window's id.
access_part :: proc(base: platform.Access_Id, part: u64) -> platform.Access_Id {
	mix :: proc(x: u64) -> u64 {
		z := x + 0x9E3779B97F4A7C15
		z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
		z = (z ~ (z >> 27)) * 0x94D049BB133111EB
		return z ~ (z >> 31)
	}
	id := mix(mix(u64(base)) + part)
	return platform.Access_Id(id == 0 ? 1 : id)
}

access_bounds :: proc(r: render.Rect) -> [4]f32 {
	return {r.x, r.y, r.width, r.height}
}

access_focused :: proc(f: Focus) -> platform.Access_Id {
	return platform.Access_Id(f.focused)
}

// Focuses the control an assistive technology asked for, with the ring, as a key would. False when the last
// completed frame registered no control with that id in the innermost open scope: the id is another
// widget's, as a menu row's, or outside a modal surface, which keeps the keyboard.
access_focus_request :: proc(f: ^Focus, e: platform.Access_Focus_Event) -> bool {
	scope := focus_scope_top(f)
	for entry in f.order {
		if entry.id == Focus_Id(e.id) && entry.scope == scope {
			focus_set(f, entry.id, true)
			return true
		}
	}
	return false
}
