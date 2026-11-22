// The Cosmos starter: one window with a 16:9 viewer that a renderer outside Cosmos draws into, as a video
// player would, and a playhead marker over it, in the family's default theme. A right click opens a menu
// with a Playback speed submenu; Ctrl+O opens videos and Ctrl+S picks where to export, in the system
// dialogs; a worker probes the chosen videos and hands its results back through an inbox. A lost graphics
// device is made again. It imports nothing but the cosmos collection. Build it with
// `odin build examples/starter -collection:cosmos=src`.
package main

import "core:log"
import "core:math"
import "core:strings"
import "cosmos:font"
import "cosmos:glyphs"
import "cosmos:host"
import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import "cosmos:theme"
import "cosmos:ui"
import d3d "vendor:directx/d3d11"

VIEWER_KEY :: render.IMAGE_KEY_TARGET | 1
VIEWER_ASPECT :: f32(16.0 / 9.0)
// Room around the viewer, in DIPs.
MARGIN :: 24
// The menu's text, in DIPs.
TEXT_SIZE :: 14
VIDEO_FILTERS :: [?]platform.File_Filter{{"Videos", "*.mp4;*.mkv;*.mov;*.webm"}, {"All files", "*.*"}}
EXPORT_FILTERS :: [?]platform.File_Filter{{"MP4 video", "*.mp4"}}

Starter :: struct {
	desktop:       platform.Platform,
	window:        input.Window_Id,
	driver:        render.Driver,
	device:        ^render.Device,
	surface:       host.Surface,
	list:          render.Draw_List,
	width, height: i32,
	scale:         f32,
	run:           host.Run,
	clock:         host.Clock,
	// The family's default theme as the widgets draw it.
	theme:         ui.Theme,
	fonts:         ^font.System,
	cache:         glyphs.Cache,
	text:          ui.Text,
	// The viewer's texture, which the stand-in renderer draws, and its size in pixels.
	viewer:        rawptr,
	viewer_size:   [2]int,
	// The stand-in renderer's playback position in frames, and how fast it plays.
	position:      f32,
	speed:         f32,
	pointer:       [2]f32,
	menu:          Context_Menu,
	// The file dialog while it is open, and what it chooses.
	pick:          ^platform.File_Pick,
	pick_mode:     platform.File_Pick_Mode,
	// The videos the open dialog chose, what the probe learned of them, and where the export goes.
	videos:        [dynamic]string,
	probed:        [dynamic]Probe_Result,
	export:        string,
	probe:         Probe,
}

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	s: Starter
	if !starter_init(&s, .Auto) {return}
	defer starter_destroy(&s)
	for host.running(s.run) {
		// The viewer plays, so the window always wants a frame: the loop sleeps until its swap chain has
		// room, an OS message arrives or the probe wakes it.
		waits: host.Frame_Waits
		host.frame_waits_add(&waits, s.surface, drawable = true, wants = true, animating = true)
		if host.frame_wait(&s.desktop, &waits, host.frame_wait_ms(waits, {}, false, {})) != .None {
			log.error("waiting for events failed")
		}
		starter_tick(&s)
		free_all(context.temp_allocator)
	}
}

@(require_results)
starter_init :: proc(s: ^Starter, driver: render.Driver) -> bool {
	if platform.init(&s.desktop, "CosmosStarter") != .Primary {return false}
	window, window_error := platform.window_create(&s.desktop, {title = "Cosmos starter", width = 1280, height = 720})
	if window_error != .None {return false}
	s.window, s.driver, s.speed = window, driver, 1
	s.width, s.height, _ = platform.window_client_size(&s.desktop, window)
	s.scale = f32(max(platform.window_dpi(&s.desktop, window), 96)) / 96
	device_error: render.Error
	s.device, device_error = render.device_create(driver)
	if device_error != .None {return false}
	native := platform.window_native_handle(&s.desktop, window)
	if host.surface_make(&s.surface, s.device, native, s.width, s.height) != .None {return false}
	fonts_error: font.Error
	s.fonts, fonts_error = font.system_create()
	if fonts_error != .None {return false}
	glyphs.init(&s.cache, s.fonts, s.device)
	if !ui.text_init(&s.text, s.fonts, &s.cache, TEXT_SIZE * s.scale) {return false}
	s.theme = ui.theme_from(theme.default(), ui.HOVER_LIFT_DEFAULT, ui.HOVER_GLOSS_DEFAULT)
	s.list = render.draw_list_init()
	menu_init(&s.menu)
	return probe_start(&s.probe, host.waker_platform(&s.desktop))
}

starter_destroy :: proc(s: ^Starter) {
	probe_stop(&s.probe)
	for &result in s.probed {probe_result_destroy(&result)}
	delete(s.probed)
	if s.pick != nil {platform.file_pick_destroy(s.pick)}
	for path in s.videos {delete(path)}
	delete(s.videos)
	delete(s.export)
	menu_destroy(&s.menu)
	render.draw_list_destroy(&s.list)
	if s.fonts != nil {
		glyphs.destroy(&s.cache)
		font.system_destroy(s.fonts)
	}
	host.surface_release(&s.surface)
	if s.device != nil {render.device_destroy(s.device)}
	_ = platform.destroy(&s.desktop)
}

// One turn of the loop: OS events, the dialog, the probe's results and the menu's timers, then a frame.
starter_tick :: proc(s: ^Starter) {
	events, _ := platform.poll_events(&s.desktop)
	for event in events {starter_event(s, event)}
	starter_poll_dialog(s)
	starter_collect_probes(s)
	menu_tick(s, host.clock_now(&s.clock))
	_, settle_error := host.surface_settle(&s.surface, s.device, platform.window_sizing(&s.desktop, s.window))
	if settle_error == .Device_Lost {starter_recover(s)}
	if starter_surface_ready(s) {starter_frame(s)}
}

starter_event :: proc(s: ^Starter, event: platform.Event) {
	#partial switch e in event {
	case platform.Close_Request_Event:
		starter_quit(s)
	case platform.Resize_Event:
		s.width, s.height = e.width, e.height
		sizing := platform.window_sizing(&s.desktop, s.window)
		if host.surface_resize(&s.surface, s.device, max(s.width, 1), max(s.height, 1), sizing) == .Device_Lost {
			starter_recover(s)
		}
	case input.Mouse_Move_Event:
		s.pointer = {f32(e.x), f32(e.y)}
		menu_hover(s, s.pointer, host.clock_now(&s.clock))
	case input.Mouse_Button_Event:
		s.pointer = {f32(e.x), f32(e.y)}
		if !e.pressed || menu_press(s, e) {return}
		if e.button == .Right {menu_open(s, s.pointer)}
	case input.Key_Event:
		if !e.pressed || menu_key(s, e) {return}
		switch {
		case e.key == .O && .Control in e.modifiers:
			starter_open_videos(s)
		case e.key == .S && .Control in e.modifiers:
			starter_export(s)
		case e.key == .Escape:
			starter_quit(s)
		}
	}
}

starter_quit :: proc(s: ^Starter) {
	host.quit(&s.run)
}

// Opens the system dialog for one or more videos, unless a dialog is open.
starter_open_videos :: proc(s: ^Starter) {
	if s.pick != nil {return}
	filters := VIDEO_FILTERS
	s.pick = platform.file_pick_start(&s.desktop, s.window, {mode = .Open_Many, filters = filters[:]})
	s.pick_mode = .Open_Many
}

// Opens the system dialog for where an export goes, unless a dialog is open.
starter_export :: proc(s: ^Starter) {
	if s.pick != nil {return}
	filters := EXPORT_FILTERS
	options := platform.File_Pick_Options {
		mode              = .Save,
		filters           = filters[:],
		file_name         = "clip.mp4",
		default_extension = "mp4",
	}
	s.pick = platform.file_pick_start(&s.desktop, s.window, options)
	s.pick_mode = .Save
}

// Takes what a dialog chose once it closes: chosen videos go to the probe; an export keeps its path.
starter_poll_dialog :: proc(s: ^Starter) {
	if s.pick == nil {return}
	paths, finished := platform.file_pick_finished(s.pick)
	if !finished {return}
	#partial switch s.pick_mode {
	case .Open_Many:
		for path in paths {
			append(&s.videos, strings.clone(path))
			probe_post(&s.probe, path)
		}
	case .Save:
		if len(paths) > 0 {
			delete(s.export)
			s.export = strings.clone(paths[0])
			log.infof("the clip would export to %s", s.export)
		}
	}
	platform.file_pick_destroy(s.pick)
	s.pick = nil
}

// Keeps what the probe has learned since the last turn.
starter_collect_probes :: proc(s: ^Starter) {
	if host.inbox_take(&s.probe.results, &s.probed) != nil {log.error("taking the probe's results failed")}
}

// Whether the window can draw, making a missing surface first; a lost device is made again.
starter_surface_ready :: proc(s: ^Starter) -> bool {
	switch _ in s.surface {
	case ^render.Surface:
		return true
	case host.Surface_Failed:
		return false
	case nil:
	}
	native := platform.window_native_handle(&s.desktop, s.window)
	if host.surface_make(&s.surface, s.device, native, s.width, s.height) == .Device_Lost {starter_recover(s)}
	return host.surface_get(s.surface) != nil
}

// Makes the graphics device and everything on it again after the GPU was reset or removed. Without a
// device nothing can draw, so the starter stops.
starter_recover :: proc(s: ^Starter) {
	log.warn("the graphics device was lost; recreating it")
	host.surface_release(&s.surface)
	// The viewer's texture belonged to the old device.
	s.viewer, s.viewer_size = nil, {}
	device, err := render.device_create(s.driver)
	if err != .None {
		log.errorf("recreating the graphics device failed: %v", err)
		host.device_failed(&s.run)
		return
	}
	render.device_destroy(s.device)
	s.device = device
	glyphs.reset_device(&s.cache, device)
	native := platform.window_native_handle(&s.desktop, s.window)
	_ = host.surface_make(&s.surface, s.device, native, s.width, s.height)
}

// Where the viewer sits in a window of this size.
viewer_rect :: proc(width, height: i32, scale: f32) -> render.Rect {
	margin := math.round(MARGIN * scale)
	area := render.Rect{margin, margin, f32(width) - 2 * margin, f32(height) - 2 * margin}
	return render.rect_fit(area, VIEWER_ASPECT)
}

// The marker over the viewer: a playhead line at a third of its width.
marker_rect :: proc(viewer: render.Rect, scale: f32) -> render.Rect {
	return {math.round(viewer.x + viewer.width / 3), viewer.y, max(1, math.round(3 * scale)), viewer.height}
}

// The stand-in renderer's colour on frame `frame`: a slow cycle through warm and cool tones.
pattern_color :: proc(frame: int) -> [4]f32 {
	phase := f32(frame % 240) / 240 * 2 * math.PI
	return {0.35 + 0.25 * math.sin(phase), 0.25, 0.45 + 0.25 * math.cos(phase), 1}
}

// Draws the next frame: the stand-in renderer fills the viewer's texture on the device's immediate
// context, then the window draws the viewer, the marker over it and the menu over everything.
starter_frame :: proc(s: ^Starter) {
	surface := host.surface_get(s.surface)
	if surface == nil {return}
	frame, ready := host.frame_begin(surface, host.clock_now(&s.clock), 0)
	if !ready {return}
	viewer := viewer_rect(s.width, s.height, s.scale)
	size := [2]int{int(viewer.width), int(viewer.height)}
	if size.x < 1 || size.y < 1 {return}
	if s.viewer == nil || s.viewer_size != size {
		texture, err := render.image_target(s.device, VIEWER_KEY, size.x, size.y)
		if err != .None {
			log.errorf("making the viewer texture failed: %v", err)
			return
		}
		s.viewer, s.viewer_size = texture, size
	}
	stand_in_render(s.device, s.viewer, pattern_color(int(s.position)))
	s.position += s.speed
	if !host.frame_build(&s.list, s.device, Starter_Build{s, viewer}, starter_build) {return}
	#partial switch err := render.frame_render(s.device, surface, &s.list, s.theme.window); err {
	case .None:
		// The viewer moves every frame.
		host.frame_end(surface, frame, presented = true, moved = true)
	case .Device_Lost:
		starter_recover(s)
	case:
		log.errorf("rendering a frame failed: %v", err)
	}
}

@(private = "file")
Starter_Build :: struct {
	s:      ^Starter,
	viewer: render.Rect,
}

// The draw list of one frame; an atlas reset stops it, and host.frame_build builds it again.
@(private = "file")
starter_build :: proc(b: Starter_Build) {
	s, viewer := b.s, b.viewer
	full := render.Rect{0, 0, f32(s.width), f32(s.height)}
	if render.push_layer(&s.list, full) != .None {return}
	if render.push_image(&s.list, {rect = viewer, uv = {0, 0, 1, 1}, key = VIEWER_KEY}) != .None {return}
	// A later layer draws over the video, as timelines, markers and menus would.
	if render.push_layer(&s.list, viewer) != .None {return}
	if render.push_rect(&s.list, {rect = marker_rect(viewer, s.scale), color = s.theme.accent}) != .None {return}
	if render.push_layer(&s.list, full) != .None {return}
	_ = menu_draw(s)
}

// What a video player does with the texture: it renders into it on the device's immediate context.
stand_in_render :: proc(device: ^render.Device, texture: rawptr, color: [4]f32) {
	native, _ := render.device_native_handles(device)
	d3d_device := (^d3d.IDevice)(native)
	ctx: ^d3d.IDeviceContext
	d3d_device->GetImmediateContext(&ctx)
	defer ctx->Release()
	view: ^d3d.IRenderTargetView
	if d3d_device->CreateRenderTargetView((^d3d.IResource)(texture), nil, &view) < 0 {return}
	defer view->Release()
	color := color
	ctx->ClearRenderTargetView(view, &color)
}
