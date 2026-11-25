package starter_headless_test

import "core:testing"
import "cosmos:host"
import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import starter "../../examples/starter"

@(private = "file")
settings_node :: proc(t: ^testing.T, nodes: []platform.Access_Node, name: string) -> platform.Access_Node {
	result, found := find_node(nodes, name)
	testing.expect(t, found, name)
	return result
}

@(private = "file")
settings_click :: proc(s: ^starter.Starter, point: [2]f32) {
	press(s, .Left, point)
	starter.starter_event(s, input.Mouse_Button_Event{window = s.window, button = .Left, x = i32(point.x), y = i32(point.y)})
}

@(private = "file")
settings_center :: proc(b: [4]f32) -> [2]f32 {return {b[0] + b[2] / 2, b[1] + b[3] / 2}}

@(test)
settings_reveals_keyboard_focus_and_restores_the_opener :: proc(t: ^testing.T) {
	s: starter.Starter
	if !open(t, &s) {return}
	defer starter.starter_destroy(&s)
	testing.expect_value(t, platform.window_set_client_size(&s.desktop, s.window, 640, 200), platform.Error.None)
	nodes, focused, ok := access_tick(t, &s)
	if !ok {return}
	opener := settings_node(t, nodes, "Settings")
	key(&s, .Tab)
	key(&s, .Enter)
	nodes, focused, ok = access_tick(t, &s)
	if !ok {return}
	dialog := settings_node(t, nodes, "Settings")
	name := settings_node(t, nodes, "Export file name")
	playhead := settings_node(t, nodes, "Show playhead")
	testing.expect_value(t, dialog.role, platform.Access_Role.Dialog)
	testing.expect_value(t, name.parent, dialog.id)
	testing.expect_value(t, focused, name.id)
	testing.expect_value(t, playhead.bounds[3], f32(0))
	key(&s, .A, {.Control})
	key(&s, .F2)
	starter.starter_event(&s, input.Key_Event{window = s.window, key = .M, pressed = true, text = "montage.mp4"})
	key(&s, .Tab)
	key(&s, .Tab)
	nodes, focused, ok = access_tick(t, &s)
	if !ok {return}
	playhead = settings_node(t, nodes, "Show playhead")
	testing.expect_value(t, settings_node(t, nodes, "Export file name").value, "montage.mp4")
	testing.expect_value(t, focused, playhead.id)
	testing.expect(t, playhead.bounds[3] >= 30, "Tab did not scroll the focused control into view")
	key(&s, .Space)
	key(&s, .Escape)
	starter.starter_event(&s, input.Key_Event{window = s.window, key = .Escape, pressed = true, repeat = true})
	nodes, focused, ok = access_tick(t, &s)
	if !ok {return}
	testing.expect_value(t, focused, opener.id)
	testing.expect_value(t, s.run, host.Run.Running)
	pixels, drawn := read_frame(t, &s)
	if !drawn {return}
	defer delete(pixels)
	viewer := starter.viewer_rect(s.width, s.height, s.scale)
	marker := starter.marker_rect(viewer, s.scale)
	expect_color(t, pixels, s.width, marker.x + 1, marker.y + marker.height / 2, starter.pattern_color(int(s.position - s.speed)), "the viewer replaces the disabled playhead")
}

@(test)
settings_dropdown_owns_overlap_and_exposes_actions :: proc(t: ^testing.T) {
	s: starter.Starter
	if !open(t, &s) {return}
	defer starter.starter_destroy(&s)
	nodes, focused, ok := access_tick(t, &s)
	if !ok {return}
	settings_click(&s, settings_center(settings_node(t, nodes, "Settings").bounds))
	nodes, _, ok = access_tick(t, &s)
	if !ok {return}
	combo := settings_node(t, nodes, "Playback speed")
	playhead := settings_node(t, nodes, "Show playhead")
	testing.expect_value(t, combo.role, platform.Access_Role.Combo_Box)
	testing.expect_value(t, platform.access_invoke(&s.desktop, s.window, combo.id, .Expand), platform.Error.None)
	nodes, _, ok = access_tick(t, &s)
	if !ok {return}
	combo = settings_node(t, nodes, "Playback speed")
	testing.expect(t, .Expanded in combo.states)
	first := settings_node(t, nodes, "0.5×")
	overlap := render.rect_intersect(transmute(render.Rect)first.bounds, transmute(render.Rect)playhead.bounds)
	if !testing.expect(t, overlap.width > 0 && overlap.height > 0, "the option must cover the switch for this test") {return}
	settings_click(&s, {overlap.x + overlap.width / 2, overlap.y + overlap.height / 2})
	nodes, focused, ok = access_tick(t, &s)
	if !ok {return}
	combo = settings_node(t, nodes, "Playback speed")
	playhead = settings_node(t, nodes, "Show playhead")
	testing.expect_value(t, combo.value, "0.5×")
	testing.expect(t, .Collapsed in combo.states && .Checked in playhead.states, "the click reached the control behind the option")
	testing.expect_value(t, focused, combo.id)
	testing.expect_value(t, platform.access_invoke(&s.desktop, s.window, playhead.id, .Toggle), platform.Error.None)
	nodes, _, ok = access_tick(t, &s)
	if !ok {return}
	testing.expect(t, .Checked not_in settings_node(t, nodes, "Show playhead").states)
}
