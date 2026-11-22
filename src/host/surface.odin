package host

import "cosmos:render"
import "core:log"

// A window's surface on the app's one graphics device. No variant: the surface is missing, and the window's
// next frame makes it; a resize waits for that. Failed: making it failed for a reason other than device
// loss, so it waits for a resize or a new device instead of failing, and logging, on every frame. Any of
// these calls can lose the device; Device_Lost is the caller's to recover, by releasing every surface,
// making a new device and making the surfaces again.
Surface :: union {
	^render.Surface,
	Surface_Failed,
}

Surface_Failed :: struct {}

// The surface to draw on, or nil while there is none.
surface_get :: proc(s: Surface) -> ^render.Surface {
	surface, _ := s.(^render.Surface)
	return surface
}

// Makes the surface for the native window `native`, `width` by `height` pixels. A failure other than device
// loss leaves it Failed, logged once.
@(require_results)
surface_make :: proc(
	s: ^Surface,
	device: ^render.Device,
	native: rawptr,
	width, height: i32,
) -> render.Error {
	surface, err := render.surface_create(device, native, max(width, 1), max(height, 1))
	#partial switch err {
	case .None:
		s^ = surface
	case .Device_Lost:
	case:
		log.errorf("making the window surface failed: %v", err)
		s^ = Surface_Failed{}
	}
	return err
}

// The window keeps asking for a frame, which is what makes the surface again.
surface_release :: proc(s: ^Surface) {
	if surface := surface_get(s^); surface != nil {render.surface_destroy(surface)}
	s^ = nil
}

// Follows the window to `width` by `height` pixels. While the user drags the frame (`sizing`, as
// platform.window_sizing says), most steps then reuse the swap chain's buffers. A failed surface is made
// again at the new size by the next frame.
@(require_results)
surface_resize :: proc(
	s: ^Surface,
	device: ^render.Device,
	width, height: i32,
	sizing: bool,
) -> render.Error {
	surface := surface_get(s^)
	if surface == nil {
		s^ = nil
		return .None
	}
	err := render.surface_resize(device, surface, width, height, sizing)
	if err != .None {log.errorf("resizing the window surface failed: %v", err)}
	return err
}

// Gives back the room a drag left in the swap chain once the drag is over. `settled` when it did, so the
// window redraws.
@(require_results)
surface_settle :: proc(s: ^Surface, device: ^render.Device, sizing: bool) -> (
	settled: bool,
	err: render.Error,
) {
	surface := surface_get(s^)
	if surface == nil || !render.surface_has_slack(surface) || sizing {return false, .None}
	err = render.surface_settle(device, surface)
	if err != .None {log.errorf("settling the window surface failed: %v", err)}
	return true, err
}
