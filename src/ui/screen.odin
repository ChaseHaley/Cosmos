package ui

import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"

// One window's layout for pointer ownership, focus traversal, and accessibility. Declare it between
// screen_begin and screen_end, outside drawing, and handle input against the completed layout.
Screen :: struct {
	focus:          Focus,
	regions:        [dynamic]Screen_Region,
	point:          [2]f32,
	pointer_inside: bool,
	owner, capture: Focus_Id,
}

// Register in reading and Tab order. For pointer picking, a higher paint layer is on top; within
// a layer, later registrations are on top. Clip is explicit: an empty clip still permits Tab.
// Passthrough affects only pointer ownership. An opaque region with id 0 or disabled
// set blocks the pointer without taking it. A nonzero id and name opt into accessibility; names and
// values are borrowed until the next layout. A semantic parent precedes its children in the same
// scope, unless separately published to the tree. Disabled and Focusable come from the bool fields.
Screen_Region :: struct {
	id:                               Focus_Id,
	rect, clip:                       render.Rect,
	scope:                            Focus_Scope,
	paint_layer:                      i32,
	focusable, disabled, passthrough: bool,
	role:                             platform.Access_Role,
	name, value:                      string,
	state:                            bit_set[platform.Access_State;u16],
	parent:                           platform.Access_Id,
}

screen_init :: proc(s: ^Screen, allocator := context.allocator) {
	focus_init(&s.focus, allocator)
	s.regions = make([dynamic]Screen_Region, allocator)
}

screen_destroy :: proc(s: ^Screen) {
	delete(s.regions)
	focus_destroy(&s.focus)
	s^ = {}
}

screen_begin :: proc(s: ^Screen) {
	clear(&s.regions)
	focus_frame_begin(&s.focus)
}

screen_add :: proc(s: ^Screen, region: Screen_Region) {
	if _, err := append(&s.regions, region); err != nil {return}
	if region.id != 0 && region.focusable && !region.disabled {
		focus_add(&s.focus, region.id, region.scope)
	}
}

screen_end :: proc(s: ^Screen) {
	focus_frame_end(&s.focus)
	screen_refresh_owner(s)
}

// The new modal scope is the only one that can own the pointer or take Tab. Any capture in the
// previous scope is canceled. The focus engine saves the current focus for when the scope closes.
screen_modal_open :: proc(s: ^Screen) -> Focus_Scope {
	scope := focus_scope_open(&s.focus)
	screen_cancel(s)
	screen_refresh_owner(s)
	return scope
}

// Close the innermost modal first. Cancel its capture and give focus back to the control that had it
// when this scope opened; a later layout reconciles focus if that control no longer exists.
screen_modal_close :: proc(s: ^Screen, scope: Focus_Scope) {
	focus_scope_close(&s.focus, scope)
	screen_cancel(s)
	screen_refresh_owner(s)
}

screen_pick :: proc(s: ^Screen, point: [2]f32) -> Focus_Id {
	region := screen_hit(s, point)
	return region == nil ? 0 : region.id
}

screen_move :: proc(s: ^Screen, point: [2]f32) {
	screen_track(s, point)
}

// Leaving clears hover, not capture: a captured press can re-enter before its release.
screen_leave :: proc(s: ^Screen) {
	s.pointer_inside = false
	s.owner = 0
}

// Call when the window loses pointer capture. Capture is separate from hover.
screen_cancel :: proc(s: ^Screen) {
	s.capture = 0
}

screen_hovered :: proc(s: ^Screen, id: Focus_Id) -> bool {
	return id != 0 && s.owner == id
}

screen_pressed :: proc(s: ^Screen, id: Focus_Id) -> bool {
	return s.capture == id && screen_hovered(s, id)
}

// Press takes capture and focuses a focusable owner without the ring. Release reports the captured
// owner even if it no longer owns the pointer, but activates only when it still owns the release.
screen_button :: proc(s: ^Screen, e: input.Mouse_Button_Event) -> (target: Focus_Id, activated: bool) {
	if e.button != .Left {return}
	region := screen_track(s, {f32(e.x), f32(e.y)})
	if e.pressed {
		s.capture = s.owner
		if region != nil && region.focusable {focus_set(&s.focus, s.capture, false)}
		return s.capture, false
	}
	target = s.capture
	screen_cancel(s)
	return target, screen_hovered(s, target)
}

// Adds the active scope's named nodes in registration order. Offscreen nodes remain available to
// assistive technology, but their bounds never extend outside the clip.
screen_access :: proc(s: ^Screen, t: ^Access_Tree) {
	scope := focus_scope_top(&s.focus)
	for &region in s.regions {
		if !screen_semantic(&region, scope) {continue}
		states := region.state
		states -= {.Disabled, .Focusable}
		if region.disabled {states += {.Disabled}} else if region.focusable {states += {.Focusable}}
		access_add(t, {
			id     = platform.Access_Id(region.id),
			parent = region.parent,
			role   = region.role,
			name   = region.name,
			value  = region.value,
			bounds = access_bounds(render.rect_intersect(region.rect, region.clip)),
			states = states,
		})
	}
}

// Resolves an assistive technology action for app dispatch. This is semantic ownership rather than a
// hit test: unlike a pointer, assistive technology can address a registered offscreen control.
screen_access_target :: proc(s: ^Screen, e: platform.Access_Invoke_Event) -> Focus_Id {
	scope := focus_scope_top(&s.focus)
	for &region in s.regions {
		if region.id != Focus_Id(e.id) || !screen_semantic(&region, scope) {continue}
		if region.disabled {return 0}
		// Match the patterns exposed by the native accessibility provider.
		submenu := region.role == .Menu_Item && (.Expanded in region.state || .Collapsed in region.state)
		switch e.action {
		case .Invoke:
			if region.role == .Button || region.role == .List_Item || (region.role == .Menu_Item && !submenu) {
				return region.id
			}
		case .Toggle:
			if region.role == .Check_Box {return region.id}
		case .Expand, .Collapse:
			if region.role == .Combo_Box || submenu {return region.id}
		}
		return 0
	}
	return 0
}

@(private)
screen_semantic :: proc(region: ^Screen_Region, scope: Focus_Scope) -> bool {
	return region.scope == scope && region.id != 0 && region.name != ""
}

@(private)
screen_hit :: proc(s: ^Screen, point: [2]f32) -> ^Screen_Region {
	scope := focus_scope_top(&s.focus)
	top: ^Screen_Region
	#reverse for &region in s.regions {
		if region.scope != scope || region.passthrough {continue}
		if top != nil && region.paint_layer <= top.paint_layer {continue}
		if !render.rect_contains(region.rect, point.x, point.y) ||
		   !render.rect_contains(region.clip, point.x, point.y) {continue}
		top = &region
	}
	return top == nil || top.disabled || top.id == 0 ? nil : top
}

@(private)
screen_track :: proc(s: ^Screen, point: [2]f32) -> ^Screen_Region {
	s.point = point
	s.pointer_inside = true
	region := screen_hit(s, point)
	s.owner = region == nil ? 0 : region.id
	return region
}

@(private)
screen_refresh_owner :: proc(s: ^Screen) {
	if s.pointer_inside {s.owner = screen_pick(s, s.point)}
}
