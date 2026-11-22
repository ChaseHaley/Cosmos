package host_test

import "cosmos:host"
import "cosmos:input"
import "core:testing"

@(private = "file")
Target :: enum u8 {Menu, Toolbar, Content}

@(private = "file")
App :: struct {
	menu_open, dragging: bool,
	hovered:             [Target]bool,
	presses, releases:   [Target]int,
	left:                int,
}

@(private = "file")
Window :: struct {
	// A floating panel covers x < 10.
	panel: bool,
}

@(private = "file")
menu_claims :: proc(app: ^App, _: ^Window, x, _: f32) -> bool {return app.menu_open && x < 50}
@(private = "file")
toolbar_claims :: proc(_: ^App, _: ^Window, _, y: f32) -> bool {return y < 20}
@(private = "file")
content_claims :: proc(_: ^App, _: ^Window, _, _: f32) -> bool {return true}

@(private = "file")
menu_hover :: proc(app: ^App, _: ^Window, owner: Target, _: input.Mouse_Move_Event) {app.hovered[.Menu] = owner == .Menu}
@(private = "file")
toolbar_hover :: proc(app: ^App, _: ^Window, owner: Target, _: input.Mouse_Move_Event) {
	app.hovered[.Toolbar] = owner == .Toolbar
}
@(private = "file")
content_hover :: proc(app: ^App, _: ^Window, owner: Target, _: input.Mouse_Move_Event) {
	app.hovered[.Content] = owner == .Content
}

@(private = "file")
toolbar_press :: proc(app: ^App, _: ^Window, _: input.Mouse_Button_Event) {app.presses[.Toolbar] += 1}
@(private = "file")
content_press :: proc(app: ^App, _: ^Window, _: input.Mouse_Button_Event) {app.presses[.Content] += 1}
@(private = "file")
toolbar_release :: proc(app: ^App, _: ^Window, _: input.Mouse_Button_Event) -> bool {
	app.releases[.Toolbar] += 1
	return true
}
@(private = "file")
toolbar_leave :: proc(app: ^App, _: ^Window) {app.left += 1}
@(private = "file")
toolbar_held :: proc(app: ^App, _: ^Window, _: Target, _: input.Mouse_Move_Event) -> host.Pointer_Held {
	return app.dragging ? .Taken : .Free
}

@(private = "file")
panel_covers :: proc(w: ^Window, x, _: f32) -> bool {return w.panel && x < 10}

@(private = "file")
surfaces := [Target]host.Pointer_Surface(App, Window, Target) {
	.Menu    = {claims = menu_claims, hover = menu_hover, modal = true},
	.Toolbar = {
		claims = toolbar_claims, hover = toolbar_hover, press = toolbar_press, release = toolbar_release,
		leave = toolbar_leave, held = toolbar_held, holds = true, under_covers = true,
	},
	.Content = {claims = content_claims, hover = content_hover, press = content_press},
}

// The topmost claiming surface owns the point, unless it is absent or covered there.
@(test)
the_topmost_shown_surface_owns_the_point :: proc(t: ^testing.T) {
	app: App
	w: Window
	target :: proc(app: ^App, w: ^Window, x, y: f32, absent: bit_set[Target] = {}) -> Target {
		return host.pointer_target(&surfaces, app, w, x, y, absent, panel_covers, Target.Content)
	}
	testing.expect_value(t, target(&app, &w, 5, 5), Target.Toolbar)
	app.menu_open = true
	testing.expect(t, target(&app, &w, 5, 5) == .Menu, "the menu is above the toolbar")
	testing.expect_value(t, target(&app, &w, 60, 5), Target.Toolbar)
	testing.expect(t, target(&app, &w, 60, 5, {.Toolbar}) == .Content, "an absent surface is skipped")
	w.panel = true
	app.menu_open = false
	testing.expect(t, target(&app, &w, 5, 5) == .Content, "the panel covers the toolbar")
	testing.expect_value(t, target(&app, &w, 15, 5), Target.Toolbar)
}

// Every surface sees each move, a held drag takes it first, and a release reaches only a surface that
// takes releases.
@(test)
moves_reach_every_surface_and_releases_their_owner :: proc(t: ^testing.T) {
	app: App
	w: Window
	host.pointer_move(&surfaces, &app, &w, Target.Toolbar, {})
	testing.expect(t, app.hovered == {.Menu = false, .Toolbar = true, .Content = false})
	host.pointer_move(&surfaces, &app, &w, Target.Content, {})
	testing.expect(t, app.hovered == {.Menu = false, .Toolbar = false, .Content = true}, "the old owner clears its hover")
	testing.expect_value(t, host.pointer_held(&surfaces, &app, &w, Target.Content, {}), host.Pointer_Held.Free)
	app.dragging = true
	testing.expect_value(t, host.pointer_held(&surfaces, &app, &w, Target.Content, {}), host.Pointer_Held.Taken)
	host.pointer_press(&surfaces, &app, &w, Target.Toolbar, {pressed = true})
	host.pointer_press(&surfaces, &app, &w, Target.Menu, {pressed = true})
	testing.expect_value(t, app.presses[.Toolbar], 1)
	testing.expect(t, host.pointer_release(&surfaces, &app, &w, Target.Toolbar, {}))
	testing.expect(t, !host.pointer_release(&surfaces, &app, &w, Target.Content, {}), "content takes no releases")
	host.pointer_leave(&surfaces, &app, &w)
	testing.expect_value(t, app.left, 1)
}
