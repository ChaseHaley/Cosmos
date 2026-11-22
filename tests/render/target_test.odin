package render_test

import "core:testing"
import "cosmos:render"
import d3d "vendor:directx/d3d11"

// A renderer outside the package, as a video player would be: it clears the target on the device's
// immediate context and leaves its own render target and a one-pixel viewport bound behind it.
@(private = "file")
foreign_draw :: proc(t: ^testing.T, device: ^render.Device, texture: rawptr, color: [4]f32) {
	native, _ := render.device_native_handles(device)
	d3d_device := (^d3d.IDevice)(native)
	ctx: ^d3d.IDeviceContext
	d3d_device->GetImmediateContext(&ctx)
	defer ctx->Release()
	view: ^d3d.IRenderTargetView
	if !testing.expect(t, d3d_device->CreateRenderTargetView((^d3d.IResource)(texture), nil, &view) >= 0) {return}
	defer view->Release()
	color := color
	ctx->ClearRenderTargetView(view, &color)
	ctx->OMSetRenderTargets(1, &view, nil)
	viewport := d3d.VIEWPORT{Width = 1, Height = 1, MaxDepth = 1}
	ctx->RSSetViewports(1, &viewport)
}

@(test)
target_shows_a_foreign_renderers_pixels_under_later_layers :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 16, 16)
	if !ok {return}
	defer fixture_destroy(&f)
	key := render.IMAGE_KEY_TARGET | 1
	texture, err := render.image_target(f.device, key, 4, 4)
	if !testing.expect_value(t, err, render.Error.None) {return}
	foreign_draw(t, f.device, texture, {1, 0, 0, 1})
	layer(t, &f.list, {0, 0, 16, 16})
	testing.expect_value(t, render.push_image(&f.list, {rect = {4, 4, 8, 8}, uv = {0, 0, 1, 1}, key = key}), render.Error.None)
	// A marker drawn in a later layer covers the video.
	layer(t, &f.list, {0, 0, 16, 16})
	rect(t, &f.list, {rect = {8, 8, 4, 4}, color = {0, 0, 1, 1}})
	pixels := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(pixels)
	// The surface is BGRA.
	expect_pixel(t, pixels, 16, 5, 5, {0, 0, 255, 255})
	expect_pixel(t, pixels, 16, 10, 10, {255, 0, 0, 255})
	expect_pixel(t, pixels, 16, 2, 2, {0, 0, 0, 255})
	expect_pixel(t, pixels, 16, 14, 14, {0, 0, 0, 255})
}

// Eviction and the image budget leave a target alone however long it goes undrawn; only releasing it
// frees it.
@(test)
target_outlives_eviction_until_released :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 4, 4)
	if !ok {return}
	defer fixture_destroy(&f)
	key := render.IMAGE_KEY_TARGET | 2
	texture, err := render.image_target(f.device, key, 2, 2)
	if !testing.expect_value(t, err, render.Error.None) {return}
	foreign_draw(t, f.device, texture, {0, 1, 0, 1})
	f.device.image_budget = 1
	for _ in 0 ..< render.IMAGE_IDLE_FRAMES + 2 {
		testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {}), render.Error.None)
	}
	testing.expect(t, render.image_known(f.device, key))
	layer(t, &f.list, {0, 0, 4, 4})
	testing.expect_value(t, render.push_image(&f.list, {rect = {0, 0, 4, 4}, uv = {0, 0, 1, 1}, key = key}), render.Error.None)
	pixels := render_pixels(t, &f, {0, 0, 0, 1})
	defer delete(pixels)
	expect_pixel(t, pixels, 4, 1, 1, {0, 255, 0, 255})
	render.image_target_release(f.device, key)
	testing.expect(t, !render.image_known(f.device, key))
}
