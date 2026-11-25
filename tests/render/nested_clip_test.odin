package render_test

import "core:testing"
import "cosmos:render"

@(test)
viewport_clips_nest_and_restore_parent_paint :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 32, 32)
	if !ok {return}
	defer fixture_destroy(&f)
	list := &f.list
	whole := render.Rect{0, 0, 32, 32}
	layer(t, list, whole)
	outer, err := render.clip_push(list, {4, 4, 20, 20})
	if !testing.expect_value(t, err, render.Error.None) {return}
	rect(t, list, {rect = {0, 16, 32, 4}, color = {1, 1, 0, 1}})
	inner, inner_err := render.clip_push(list, {12.75, 0, 16, 16})
	if !testing.expect_value(t, inner_err, render.Error.None) {return}
	rect(t, list, {rect = whole, color = {1, 0, 0, 1}})
	layer(t, list, whole)
	rect(t, list, {rect = {0, 8, 32, 4}, color = {0, 0, 1, 1}})
	testing.expect_value(t, render.clip_pop(list, inner), render.Error.None)
	rect(t, list, {rect = {0, 12, 32, 4}, color = {0, 1, 0, 1}})
	testing.expect_value(t, render.clip_pop(list, outer), render.Error.None)
	rect(t, list, {rect = {0, 20, 32, 8}, color = {1, 1, 1, 1}})

	pixels := render_pixels(t, &f)
	defer delete(pixels)
	expect_pixel(t, pixels, 32, 16, 3, {})
	expect_pixel(t, pixels, 32, 12, 5, {})
	expect_pixel(t, pixels, 32, 13, 5, {0, 0, 255, 255})
	expect_pixel(t, pixels, 32, 24, 5, {})
	expect_pixel(t, pixels, 32, 11, 9, {})
	expect_pixel(t, pixels, 32, 23, 9, {255, 0, 0, 255})
	expect_pixel(t, pixels, 32, 24, 9, {})
	expect_pixel(t, pixels, 32, 4, 13, {0, 255, 0, 255})
	expect_pixel(t, pixels, 32, 24, 13, {})
	expect_pixel(t, pixels, 32, 4, 17, {0, 255, 255, 255})
	expect_pixel(t, pixels, 32, 26, 22, {255, 255, 255, 255})
}

@(test)
viewport_scissors_preserve_rounded_masks_without_repeating_blur :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 32, 32)
	if !ok {return}
	defer fixture_destroy(&f)
	list := &f.list
	whole := render.Rect{0, 0, 32, 32}
	testing.expect_value(t, render.push_backdrop_blur(list, whole, 2, 12), render.Error.None)
	scope, err := render.clip_push(list, {0, 0, 20, 24})
	if !testing.expect_value(t, err, render.Error.None) {return}
	rect(t, list, {rect = whole, color = {1, 0, 0, 1}})
	testing.expect_value(t, render.push_layer(list, {6, 6, 20, 20}, 8), render.Error.None)
	rect(t, list, {rect = whole, color = {0, 0, 1, 1}})
	testing.expect_value(t, render.clip_pop(list, scope), render.Error.None)
	rect(t, list, {rect = {0, 26, 32, 6}, color = {0, 1, 0, 1}})

	pixels := render_pixels(t, &f)
	defer delete(pixels)
	expect_pixel(t, pixels, 32, 0, 0, {})
	expect_pixel(t, pixels, 32, 6, 6, {0, 0, 255, 255})
	// The child mask is centred on its own rect, not the narrower scissor. The neighbouring
	// clear pixel also catches a blur incorrectly replayed by the restored backdrop layer.
	expect_pixel(t, pixels, 32, 19, 7, {255, 0, 0, 255})
	expect_pixel(t, pixels, 32, 20, 7, {})
	expect_pixel(t, pixels, 32, 0, 31, {})
	expect_pixel(t, pixels, 32, 16, 31, {0, 255, 0, 255})
}
