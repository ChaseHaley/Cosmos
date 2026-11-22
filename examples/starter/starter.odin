// The Cosmos starter: one window with a 16:9 viewer that a renderer outside Cosmos draws into, as a video
// player would, a marker drawn over it, and the system file dialog on Ctrl+O. It imports nothing but the
// cosmos collection. Build it with `odin build examples/starter -collection:cosmos=src`.
package main

import "core:log"
import "core:math"
import "core:strings"
import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import d3d "vendor:directx/d3d11"

VIEWER_KEY :: render.IMAGE_KEY_TARGET | 1
VIEWER_ASPECT :: f32(16.0 / 9.0)
BACKGROUND :: render.Color{0.07, 0.07, 0.09, 1}
MARKER :: render.Color{0.98, 0.62, 0.17, 1}
// Room around the viewer, in pixels.
MARGIN :: 24
// When the swap chain cannot pace the loop, as offscreen, frames follow a 60 Hz clock.
FRAME_TIMEOUT_MS :: 16

Starter :: struct {
	desktop:       platform.Platform,
	window:        input.Window_Id,
	device:        ^render.Device,
	surface:       ^render.Surface,
	list:          render.Draw_List,
	width, height: i32,
	// The viewer's texture, which the stand-in renderer draws, and its size in pixels.
	viewer:        rawptr,
	viewer_size:   [2]int,
	// The stand-in renderer's frame count, as a video's playback position.
	frame:         int,
	// The file dialog while it is open, and what it last chose.
	pick:          ^platform.File_Pick,
	chosen:        string,
	running:       bool,
}

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	s: Starter
	if !starter_init(&s, .Auto) {return}
	defer starter_destroy(&s)
	for s.running {
		// The viewer plays, so the loop waits only for the swap chain's next frame or an OS message.
		frames: [1]rawptr
		frames[0] = render.frame_waitable(s.surface)
		count := frames[0] != nil ? 1 : 0
		signaled, err := platform.wait_events(&s.desktop, FRAME_TIMEOUT_MS, frames[:count])
		if err != .None {log.error("waiting for events failed")}
		if signaled == 0 {render.frame_signaled(s.surface)}
		starter_tick(&s)
		free_all(context.temp_allocator)
	}
}

@(require_results)
starter_init :: proc(s: ^Starter, driver: render.Driver) -> bool {
	if platform.init(&s.desktop, "CosmosStarter") != .Primary {return false}
	window, window_error := platform.window_create(&s.desktop, {title = "Cosmos starter", width = 1280, height = 720})
	if window_error != .None {return false}
	s.window = window
	s.width, s.height, _ = platform.window_client_size(&s.desktop, window)
	device_error: render.Error
	s.device, device_error = render.device_create(driver)
	if device_error != .None {return false}
	native := platform.window_native_handle(&s.desktop, window)
	surface_error: render.Error
	s.surface, surface_error = render.surface_create(s.device, native, max(s.width, 1), max(s.height, 1))
	if surface_error != .None {return false}
	s.list = render.draw_list_init()
	s.running = true
	return true
}

starter_destroy :: proc(s: ^Starter) {
	if s.pick != nil {platform.file_pick_destroy(s.pick)}
	delete(s.chosen)
	render.draw_list_destroy(&s.list)
	if s.surface != nil {render.surface_destroy(s.surface)}
	if s.device != nil {render.device_destroy(s.device)}
	_ = platform.destroy(&s.desktop)
}

// One turn of the loop: OS events, the file dialog, then a frame.
starter_tick :: proc(s: ^Starter) {
	events, _ := platform.poll_events(&s.desktop)
	for event in events {starter_event(s, event)}
	starter_poll_file(s)
	if ready, _ := render.frame_acquire(s.surface, 0); ready {starter_frame(s)}
}

starter_event :: proc(s: ^Starter, event: platform.Event) {
	#partial switch e in event {
	case platform.Close_Request_Event:
		s.running = false
	case platform.Resize_Event:
		s.width, s.height = e.width, e.height
		if err := render.surface_resize(s.device, s.surface, max(s.width, 1), max(s.height, 1)); err != .None {
			log.errorf("resizing the surface failed: %v", err)
		}
	case input.Key_Event:
		if e.pressed && e.key == .O && .Control in e.modifiers {starter_open_file(s)}
		if e.pressed && e.key == .Escape {s.running = false}
	}
}

// Opens the system file dialog for a video, unless one is open.
starter_open_file :: proc(s: ^Starter) {
	if s.pick != nil {return}
	s.pick = platform.file_pick_start(&s.desktop, s.window, "Videos", "*.mp4;*.mkv;*.mov;*.webm", "")
}

starter_poll_file :: proc(s: ^Starter) {
	if s.pick == nil {return}
	path, finished := platform.file_pick_finished(s.pick)
	if !finished {return}
	if path != "" {
		delete(s.chosen)
		s.chosen = strings.clone(path)
		log.infof("chose %s", s.chosen)
	}
	platform.file_pick_destroy(s.pick)
	s.pick = nil
}

// Where the viewer sits in a window of this size.
viewer_rect :: proc(width, height: i32) -> render.Rect {
	area := render.Rect{MARGIN, MARGIN, f32(width) - 2 * MARGIN, f32(height) - 2 * MARGIN}
	return render.rect_fit(area, VIEWER_ASPECT)
}

// The marker over the viewer: a playhead line at a third of its width.
marker_rect :: proc(viewer: render.Rect) -> render.Rect {
	return {math.round(viewer.x + viewer.width / 3), viewer.y, 3, viewer.height}
}

// The stand-in renderer's colour on frame `frame`: a slow cycle through warm and cool tones.
pattern_color :: proc(frame: int) -> [4]f32 {
	phase := f32(frame % 240) / 240 * 2 * math.PI
	return {0.35 + 0.25 * math.sin(phase), 0.25, 0.45 + 0.25 * math.cos(phase), 1}
}

// Draws the next frame: the stand-in renderer fills the viewer's texture on the device's immediate
// context, then the window draws the viewer and the marker over it.
starter_frame :: proc(s: ^Starter) {
	viewer := viewer_rect(s.width, s.height)
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
	stand_in_render(s.device, s.viewer, pattern_color(s.frame))
	s.frame += 1
	render.draw_list_reset(&s.list)
	full := render.Rect{0, 0, f32(s.width), f32(s.height)}
	if render.push_layer(&s.list, full) != .None {return}
	if render.push_image(&s.list, {rect = viewer, uv = {0, 0, 1, 1}, key = VIEWER_KEY}) != .None {return}
	// A later layer draws over the video, as timelines, markers and menus would.
	if render.push_layer(&s.list, viewer) != .None {return}
	if render.push_rect(&s.list, {rect = marker_rect(viewer), color = MARKER}) != .None {return}
	if err := render.frame_render(s.device, s.surface, &s.list, BACKGROUND); err != .None {
		log.errorf("rendering a frame failed: %v", err)
	}
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
