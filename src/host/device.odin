package host

import "base:runtime"
import "cosmos:render"
import "core:thread"

// Creates the graphics device on a thread of its own: the driver takes longer to make one than an app
// takes to load its settings and fonts, which it can do meanwhile.
Device_Start :: struct {
	driver:  render.Driver,
	options: render.Device_Options,
	device:  ^render.Device,
	err:     render.Error,
	thread:  ^thread.Thread,
}

device_start :: proc(s: ^Device_Start, driver: render.Driver, options: render.Device_Options = {}) {
	s.driver, s.options = driver, options
	s.thread = thread.create_and_start_with_poly_data(s, device_start_thread, context)
}

@(private)
device_start_thread :: proc(s: ^Device_Start) {
	defer if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
		runtime.default_temp_allocator_destroy(cast(^runtime.Default_Temp_Allocator)context.temp_allocator.data)
	}
	s.device, s.err = render.device_create(s.driver, s.options)
}

// The device device_start began, which the caller now owns; made here when no thread could start.
@(require_results)
device_finish :: proc(s: ^Device_Start) -> (device: ^render.Device, err: render.Error) {
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	} else if s.device == nil && s.err == .None {
		s.device, s.err = render.device_create(s.driver, s.options)
	}
	device, err = s.device, s.err
	s.device = nil
	return
}

// Ends a start nobody finished, as when an app fails to start before it needs the device.
device_abandon :: proc(s: ^Device_Start) {
	if s.thread == nil && s.device == nil {return}
	if device, _ := device_finish(s); device != nil {render.device_destroy(device)}
}
