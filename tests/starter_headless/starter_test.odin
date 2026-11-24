package starter_headless_test

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"
import "cosmos:host"
import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import "cosmos:ui"
import starter "../../examples/starter"

// The headless platform and WARP: nothing opens on the desktop and the pixels are the same everywhere.
@(private = "file")
open :: proc(t: ^testing.T, s: ^starter.Starter) -> bool {
	return testing.expect(t, starter.starter_init(s, .Warp), "the starter did not start")
}

@(private = "file")
expect_color :: proc(t: ^testing.T, pixels: []u8, width: i32, x, y: f32, color: [4]f32, what: string) {
	index := (int(y) * int(width) + int(x)) * 4
	if !testing.expect(t, index + 4 <= len(pixels), what) {return}
	// The surface is BGRA.
	expected := [4]f32{color.b, color.g, color.r, color.a}
	for channel in 0 ..< 4 {
		actual := int(pixels[index + channel])
		wanted := int(math.round(expected[channel] * 255))
		testing.expectf(t, abs(actual - wanted) <= 2, "%s channel %d: got %d, expected %d", what, channel, actual, wanted)
	}
}

@(private = "file")
read_frame :: proc(t: ^testing.T, s: ^starter.Starter) -> ([]u8, bool) {
	starter.starter_frame(s)
	pixels, err := render.surface_read_pixels(s.device, s.surface.(^render.Surface), context.allocator)
	return pixels, testing.expect_value(t, err, render.Error.None)
}

@(private = "file")
key :: proc(s: ^starter.Starter, k: input.Key, modifiers: input.Modifiers = {}) {
	starter.starter_event(s, input.Key_Event{window = s.window, key = k, modifiers = modifiers, pressed = true})
}

@(private = "file")
press :: proc(s: ^starter.Starter, button: input.Mouse_Button, point: [2]f32) {
	starter.starter_event(s, input.Mouse_Button_Event{window = s.window, button = button, pressed = true, x = i32(point.x), y = i32(point.y)})
}

@(private = "file")
move :: proc(s: ^starter.Starter, point: [2]f32) {
	starter.starter_event(s, input.Mouse_Move_Event{window = s.window, x = i32(point.x), y = i32(point.y)})
}

@(private = "file")
row_center :: proc(s: ^starter.Starter, m: ^ui.Menu, row: int) -> [2]f32 {
	r := ui.menu_row_rect(m, row, f32(s.width), f32(s.height), s.scale)
	return {r.x + r.width / 2, r.y + r.height / 2}
}

// The family theme's window colour fills the background and its accent draws the playhead over the
// renderer's viewer.
@(test)
frame_shows_the_renderers_viewer_under_its_marker :: proc(t: ^testing.T) {
	s: starter.Starter
	if !open(t, &s) {return}
	defer starter.starter_destroy(&s)
	pixels, ok := read_frame(t, &s)
	if !ok {return}
	defer delete(pixels)
	viewer := starter.viewer_rect(s.width, s.height, s.scale)
	// Whole-pixel edges keep the ratio within a pixel of 16:9.
	testing.expect(t, abs(viewer.width - viewer.height * starter.VIEWER_ASPECT) <= 1, "viewer is not 16:9")
	middle := viewer.y + viewer.height / 2
	expect_color(t, pixels, s.width, viewer.x + viewer.width * 0.75, middle, starter.pattern_color(0), "viewer")
	expect_color(t, pixels, s.width, starter.marker_rect(viewer, s.scale).x + 1, middle, s.theme.accent, "marker")
	expect_color(t, pixels, s.width, 4, 4, s.theme.window, "background")
}

// Ctrl+O opens a dialog for many videos; the probe reads each chosen one on its worker and hands its size
// back. Ctrl+S picks where to export.
@(test)
dialogs_choose_videos_the_probe_reads_and_an_export :: proc(t: ^testing.T) {
	s: starter.Starter
	if !open(t, &s) {return}
	defer starter.starter_destroy(&s)
	directory := os.get_working_directory(context.temp_allocator) or_else "."
	video, _ := filepath.join({directory, "starter-probe.mp4"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(video, transmute([]u8)string("not really a video")), nil) {return}
	defer os.remove(video)
	missing, _ := filepath.join({directory, "starter-missing.mp4"}, context.temp_allocator)
	testing.expect_value(t, platform.file_pick_script(&s.desktop, video, missing), platform.Error.None)
	key(&s, .O, {.Control})
	if !testing.expect(t, s.pick != nil, "Ctrl+O opened no dialog") {return}
	starter.starter_poll_dialog(&s)
	testing.expect(t, s.pick == nil, "the finished dialog stayed open")
	testing.expect_value(t, len(s.videos), 2)
	deadline := time.tick_add(time.tick_now(), 5 * time.Second)
	for len(s.probed) < 2 && time.tick_diff(time.tick_now(), deadline) > 0 {
		time.sleep(time.Millisecond)
		starter.starter_collect_probes(&s)
	}
	if !testing.expect_value(t, len(s.probed), 2) {return}
	for result in s.probed {
		if result.path == video {
			testing.expect(t, result.ok && result.size == len("not really a video"), "the probe read the video")
		} else {
			testing.expect(t, !result.ok, "a missing video probes as unreadable")
		}
	}
	records := s.desktop.record.file_picks[:]
	testing.expect_value(t, records[0].options.mode, platform.File_Pick_Mode.Open_Many)
	testing.expect_value(t, len(records[0].options.filters), 2)

	testing.expect_value(t, platform.file_pick_script(&s.desktop, `C:\clips\cut.mp4`), platform.Error.None)
	key(&s, .S, {.Control})
	starter.starter_poll_dialog(&s)
	testing.expect_value(t, s.export, `C:\clips\cut.mp4`)
	testing.expect_value(t, s.desktop.record.file_picks[1].options.mode, platform.File_Pick_Mode.Save)
	testing.expect_value(t, s.desktop.record.file_picks[1].options.default_extension, "mp4")
}

// A right click opens the menu; resting on Playback speed opens its submenu, which draws over the viewer
// in the theme's surface colour; choosing 2× sets the speed and closes both.
@(test)
context_menu_sets_the_playback_speed_through_its_submenu :: proc(t: ^testing.T) {
	s: starter.Starter
	if !open(t, &s) {return}
	defer starter.starter_destroy(&s)
	viewer := starter.viewer_rect(s.width, s.height, s.scale)
	press(&s, .Right, {viewer.x + 40, viewer.y + 40})
	if !testing.expect(t, s.menu.shown, "a right click opened no menu") {return}
	speed := row_center(&s, &s.menu.menu, 3)
	move(&s, speed)
	starter.menu_tick(&s, time.tick_add(time.tick_now(), 10 * time.Millisecond))
	testing.expect(t, !ui.submenu_shown(&s.menu.submenu), "not before the delay")
	starter.menu_tick(&s, time.tick_add(time.tick_now(), time.Second))
	if !testing.expect(t, ui.submenu_shown(&s.menu.submenu), "resting opened no submenu") {return}

	pixels, ok := read_frame(t, &s)
	if !ok {return}
	defer delete(pixels)
	surface, _ := ui.menu_layout(&s.menu.submenu.menu, f32(s.width), f32(s.height), s.scale)
	inside := [2]f32{surface.x + surface.width - 6, surface.y + surface.height / 2}
	index := (int(inside.y) * int(s.width) + int(inside.x)) * 4
	behind := starter.pattern_color(0)
	drawn := [3]f32{f32(pixels[index + 2]), f32(pixels[index + 1]), f32(pixels[index])} / 255
	testing.expect(t, abs(drawn.r - behind.r) + abs(drawn.g - behind.g) + abs(drawn.b - behind.b) > 0.1, "the submenu draws over the viewer")

	press(&s, .Left, row_center(&s, &s.menu.submenu.menu, 2))
	testing.expect_value(t, s.speed, f32(2))
	testing.expect(t, !s.menu.shown && !ui.submenu_shown(&s.menu.submenu), "choosing closed the menus")
}

// The keyboard opens the submenu at once with Right, and Escape closes the menu before it quits.
@(test)
menu_keys_open_the_submenu_and_escape_closes_before_quitting :: proc(t: ^testing.T) {
	s: starter.Starter
	if !open(t, &s) {return}
	defer starter.starter_destroy(&s)
	press(&s, .Right, {100, 100})
	ui.menu_select(&s.menu.menu, 3)
	key(&s, .Arrow_Right)
	testing.expect(t, ui.submenu_shown(&s.menu.submenu), "Right opened no submenu")
	testing.expect_value(t, ui.menu_selected(&s.menu.submenu.menu), 0)
	key(&s, .Enter)
	testing.expect_value(t, s.speed, f32(0.5))
	press(&s, .Right, {100, 100})
	key(&s, .Escape)
	testing.expect(t, !s.menu.shown)
	testing.expect_value(t, s.run, host.Run.Running)
	key(&s, .Escape)
	testing.expect(t, s.run == .Quit, "Escape with no menu quits")
}

// Moving the window onto a 144 DPI display scales the starter by 1.5: the menu's text grows, an open menu
// closes, and a menu opened there lays its rows out at the new scale, so a click on its Quit row quits.
@(test)
moving_to_a_display_of_another_dpi_rescales_the_starter :: proc(t: ^testing.T) {
	s: starter.Starter
	if !open(t, &s) {return}
	defer starter.starter_destroy(&s)
	displays := []platform.Display {
		{rect = {0, 0, 1920, 1080}, dpi = 96},
		{rect = {1920, 0, 3840, 2160}, dpi = 144},
	}
	testing.expect_value(t, platform.set_displays(&s.desktop, displays), platform.Error.None)
	press(&s, .Right, {100, 100})
	if !testing.expect(t, s.menu.shown, "a right click opened no menu") {return}
	testing.expect_value(t, platform.window_set_position(&s.desktop, s.window, 2400, 100), platform.Error.None)
	starter.starter_tick(&s)
	testing.expect_value(t, s.scale, f32(1.5))
	testing.expect_value(t, s.text.size_px, f32(starter.TEXT_SIZE * 1.5))
	testing.expect(t, !s.menu.shown, "the menu placed at the old scale stayed open")

	press(&s, .Right, {100, 100})
	quit := ui.menu_row_rect(&s.menu.menu, 5, f32(s.width), f32(s.height), 1.5)
	press(&s, .Left, {quit.x + quit.width / 2, quit.y + quit.height / 2})
	testing.expect(t, s.run == .Quit, "a click on Quit at the new scale missed it")
}

// The node of the last committed tree named `name`, as a screen reader finds it.
@(private = "file")
find_node :: proc(nodes: []platform.Access_Node, name: string) -> (platform.Access_Node, bool) {
	for node in nodes {
		if node.name == name {return node, true}
	}
	return {}, false
}

// The tree of the frame the starter drew last, after it took the events queued for it.
@(private = "file")
access_tick :: proc(
	t: ^testing.T,
	s: ^starter.Starter,
) -> (
	[]platform.Access_Node,
	platform.Access_Id,
	bool,
) {
	starter.starter_tick(s)
	nodes, focus, err := platform.window_access(&s.desktop, s.window)
	return nodes, focus, testing.expect_value(t, err, platform.Error.None)
}

// A screen reader reads the viewer and the open menu, its rows named as shown with focus on the selected
// one, and works it: focusing a row selects it, Expand on Playback speed opens the submenu under its row,
// Invoke on a speed sets it and closes the menus, and Invoke on Quit quits.
@(test)
screen_readers_read_and_work_the_context_menu :: proc(t: ^testing.T) {
	s: starter.Starter
	if !open(t, &s) {return}
	defer starter.starter_destroy(&s)
	press(&s, .Right, {100, 100})
	key(&s, .End)
	nodes, focus, ok := access_tick(t, &s)
	if !ok {return}
	viewer := starter.viewer_rect(s.width, s.height, s.scale)
	video, has_video := find_node(nodes, "Video")
	testing.expect(t, has_video && video.role == .Image && video.parent == 0, "the viewer is not an Image")
	testing.expect_value(t, video.bounds, [4]f32{viewer.x, viewer.y, viewer.width, viewer.height})
	menu, has_menu := find_node(nodes, "Context menu")
	if !testing.expect(t, has_menu && menu.role == .Menu, "the open menu is not a Menu") {return}
	items: [dynamic]string
	defer delete(items)
	for node in nodes {
		if node.parent == menu.id {
			testing.expect_value(t, node.role, platform.Access_Role.Menu_Item)
			append(&items, node.name)
		}
	}
	testing.expect_value(t, len(items), 4)
	if len(items) == 4 {
		for name, i in ([?]string{"Open videos…", "Export clip…", "Playback speed", "Quit"}) {
			testing.expect_value(t, items[i], name)
		}
	}
	quit, _ := find_node(nodes, "Quit")
	quit_rect := ui.menu_row_rect(&s.menu.menu, 5, f32(s.width), f32(s.height), s.scale)
	testing.expect_value(t, quit.bounds, [4]f32{quit_rect.x, quit_rect.y, quit_rect.width, quit_rect.height})
	testing.expect_value(t, focus, quit.id)

	export, _ := find_node(nodes, "Export clip…")
	testing.expect_value(t, platform.access_focus(&s.desktop, s.window, export.id), platform.Error.None)
	nodes, focus, ok = access_tick(t, &s)
	if !ok {return}
	testing.expect_value(t, ui.menu_selected(&s.menu.menu), 1)
	testing.expect_value(t, focus, export.id)

	speed, _ := find_node(nodes, "Playback speed")
	testing.expect(t, .Collapsed in speed.states, "the closed submenu's row is not Collapsed")
	testing.expect_value(t, platform.access_invoke(&s.desktop, s.window, speed.id, .Expand), platform.Error.None)
	nodes, focus, ok = access_tick(t, &s)
	if !ok {return}
	if !testing.expect(t, ui.submenu_shown(&s.menu.submenu), "Expand opened no submenu") {return}
	speed, _ = find_node(nodes, "Playback speed")
	testing.expect(t, .Expanded in speed.states, "the open submenu's row is not Expanded")
	submenu: platform.Access_Node
	for node in nodes {
		if node.role == .Menu && node.parent == speed.id {submenu = node}
	}
	testing.expect(t, submenu.id != 0, "the submenu does not hang under its row")
	half, _ := find_node(nodes, "0.5×")
	testing.expect_value(t, half.parent, submenu.id)
	testing.expect_value(t, focus, half.id)
	double, _ := find_node(nodes, "2×")
	chose := platform.access_invoke(&s.desktop, s.window, double.id, .Invoke)
	testing.expect_value(t, chose, platform.Error.None)
	nodes, focus, ok = access_tick(t, &s)
	if !ok {return}
	testing.expect_value(t, s.speed, f32(2))
	testing.expect(t, !s.menu.shown, "choosing a speed left the menu open")
	testing.expect_value(t, len(nodes), 1)
	testing.expect_value(t, focus, platform.Access_Id(0))

	press(&s, .Right, {100, 100})
	nodes, _, ok = access_tick(t, &s)
	if !ok {return}
	quit, _ = find_node(nodes, "Quit")
	testing.expect_value(t, platform.access_invoke(&s.desktop, s.window, quit.id, .Invoke), platform.Error.None)
	starter.starter_tick(&s)
	testing.expect(t, s.run == .Quit, "Invoke on Quit did not quit")
}
