package host_test

import "base:runtime"
import "core:testing"
import "core:time"
import "cosmos:host"
import "cosmos:render"

// A window without a surface draws at once; one that cannot present, or whose surface failed, keeps the
// loop on the assumed refresh only while it animates; a window with nothing to draw adds nothing.
@(test)
frame_waits_follow_what_each_window_can_do :: proc(t: ^testing.T) {
	waits: host.Frame_Waits
	host.frame_waits_add(&waits, host.Surface_Failed{}, drawable = true, wants = true, animating = false)
	host.frame_waits_add(&waits, nil, drawable = false, wants = true, animating = false)
	host.frame_waits_add(&waits, nil, drawable = true, wants = false, animating = false)
	testing.expect(t, !waits.ready && !waits.unpaced && waits.count == 0)
	now := time.tick_now()
	deadline := time.tick_add(now, 40 * time.Millisecond)
	testing.expect_value(t, host.frame_wait_ms(waits, deadline, true, now), 41)
	testing.expect_value(t, host.frame_wait_ms(waits, {}, false, now), max(u32))

	host.frame_waits_add(&waits, host.Surface_Failed{}, drawable = true, wants = false, animating = true)
	testing.expect(t, waits.unpaced)
	period := u32(time.duration_milliseconds(render.FRAME_PERIOD_DEFAULT))
	testing.expect_value(t, host.frame_wait_ms(waits, deadline, true, now), period)
	host.frame_waits_add(&waits, nil, drawable = true, wants = true, animating = false)
	testing.expect(t, waits.ready)
	testing.expect_value(t, host.frame_wait_ms(waits, deadline, true, now), 0)
}

@(private = "file")
Build_Count :: struct {
	list:   ^render.Draw_List,
	builds: int,
	fail:   bool,
}

@(private = "file")
build_once :: proc(c: ^Build_Count) {
	c.builds += 1
	if c.fail {c.list.rects.allocator = runtime.Allocator{procedure = refuse}}
	_ = render.push_layer(c.list, {0, 0, 100, 100})
	_ = render.push_rect(c.list, {rect = {0, 0, 10, 10}, color = {1, 0, 0, 1}})
}

@(private = "file")
refuse :: proc(
	_: rawptr,
	mode: runtime.Allocator_Mode,
	_, _: int,
	_: rawptr,
	_: int,
	_ := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	return nil, mode == .Free || mode == .Free_All ? .None : .Out_Of_Memory
}

// A completed draw list is ready after one build; a build that runs out of memory fails, so the window
// keeps wanting its frame.
@(test)
frame_build_reports_only_a_completed_list :: proc(t: ^testing.T) {
	device, err := render.device_create(.Warp)
	if !testing.expect_value(t, err, render.Error.None) {return}
	defer render.device_destroy(device)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	count := Build_Count {
		list = &list,
	}
	testing.expect(t, host.frame_build(&list, device, &count, build_once))
	testing.expect_value(t, count.builds, 1)
	testing.expect_value(t, len(list.rects), 1)

	render.draw_list_destroy(&list)
	list = render.draw_list_init()
	count = {list = &list, fail = true}
	context.logger = {}
	testing.expect(t, !host.frame_build(&list, device, &count, build_once))
	list.rects.allocator = context.allocator
}
