package ui_test

import "cosmos:input"
import "cosmos:ui"
import "core:testing"
import "core:time"

@(private = "file")
WIDTH :: f32(800)
@(private = "file")
HEIGHT :: f32(600)
@(private = "file")
SCALE :: f32(1)

// A menu whose second and third rows have submenus.
@(private = "file")
parent_build :: proc(m: ^ui.Menu) {
	ui.menu_init(m)
	ui.menu_anchor(m, 40, 40)
	_ = ui.menu_add(m, {label = "plain", enabled = true})
	_ = ui.menu_add(m, {label = "more", enabled = true, submenu = true})
	_ = ui.menu_add(m, {label = "other", enabled = true, submenu = true})
}

// What an owner's open does: builds the rows and places them beside row `row`.
@(private = "file")
submenu_build :: proc(sub: ^ui.Submenu, parent: ^ui.Menu, row: int, select_first: bool) {
	ui.menu_init(&sub.menu)
	for label in ([?]string{"first", "second", "third"}) {_ = ui.menu_add(&sub.menu, {label = label, enabled = true})}
	ui.submenu_place(sub, parent, row, 200, select_first, WIDTH, HEIGHT, SCALE)
}

@(private = "file")
row_center :: proc(m: ^ui.Menu, row: int) -> [2]f32 {
	r := ui.menu_row_rect(m, row, WIDTH, HEIGHT, SCALE)
	return {r.x + r.width / 2, r.y + r.height / 2}
}

@(private = "file")
key :: proc(k: input.Key) -> input.Key_Event {
	return {key = k, pressed = true}
}

// A row's submenu waits out SUBMENU_DELAY under a resting pointer, and a move to another row starts the
// wait again for that row.
@(test)
submenu_shows_after_the_pointer_rests_on_its_row :: proc(t: ^testing.T) {
	parent: ui.Menu
	parent_build(&parent)
	defer ui.menu_destroy(&parent)
	sub: ui.Submenu
	defer ui.menu_destroy(&sub.menu)
	start := time.tick_now()
	more, other := row_center(&parent, 1), row_center(&parent, 2)
	keeps, _ := ui.submenu_hover(&sub, &parent, more, start, WIDTH, HEIGHT, SCALE)
	testing.expect(t, !keeps)
	_, due := ui.submenu_due(&sub, &parent, more, time.tick_add(start, 50 * time.Millisecond), WIDTH, HEIGHT, SCALE)
	testing.expect(t, !due, "not before the delay")
	_, _ = ui.submenu_hover(&sub, &parent, other, time.tick_add(start, 60 * time.Millisecond), WIDTH, HEIGHT, SCALE)
	_, due = ui.submenu_due(&sub, &parent, other, time.tick_add(start, 120 * time.Millisecond), WIDTH, HEIGHT, SCALE)
	testing.expect(t, !due, "the next row waits from when the pointer reached it")
	deadline, waiting := ui.submenu_deadline(&sub)
	testing.expect(t, waiting)
	testing.expect_value(t, deadline, time.tick_add(start, 160 * time.Millisecond))
	row: int
	row, due = ui.submenu_due(&sub, &parent, other, deadline, WIDTH, HEIGHT, SCALE)
	testing.expect(t, due)
	testing.expect_value(t, row, 2)
	_, due = ui.submenu_due(&sub, &parent, other, deadline, WIDTH, HEIGHT, SCALE)
	testing.expect(t, !due, "once")
}

// Leaving the row for its submenu across the next row keeps it within the grace; a pointer that stops short
// gives the hover back once the grace is over.
@(test)
submenu_keeps_an_aim_and_closes_when_it_stops_short :: proc(t: ^testing.T) {
	parent: ui.Menu
	parent_build(&parent)
	defer ui.menu_destroy(&parent)
	sub: ui.Submenu
	defer ui.menu_destroy(&sub.menu)
	start := time.tick_now()
	more := row_center(&parent, 1)
	submenu_build(&sub, &parent, 1, false)
	ui.submenu_aim(&sub, &parent, more, start, WIDTH, HEIGHT, SCALE)
	testing.expect(t, ui.submenu_shown(&sub))
	trigger := ui.menu_row_rect(&parent, 1, WIDTH, HEIGHT, SCALE)
	surface, _ := ui.menu_layout(&sub.menu, WIDTH, HEIGHT, SCALE)
	testing.expect(t, surface.x >= trigger.x + trigger.width, "it hangs on the right")
	crossing := [2]f32{trigger.x + trigger.width - 4, trigger.y + trigger.height + 4}
	testing.expect_value(t, ui.menu_hit(&parent, crossing.x, crossing.y, WIDTH, HEIGHT, SCALE), 2)
	left := time.tick_add(start, 10 * time.Millisecond)
	keeps, _ := ui.submenu_hover(&sub, &parent, crossing, left, WIDTH, HEIGHT, SCALE)
	testing.expect(t, keeps, "the aim keeps it over the next row")
	testing.expect(t, ui.submenu_shown(&sub))
	testing.expect(t, !ui.submenu_tick(&sub, time.tick_add(left, 200 * time.Millisecond)))
	deadline, waiting := ui.submenu_deadline(&sub)
	testing.expect(t, waiting)
	testing.expect(t, ui.submenu_tick(&sub, deadline), "stopped short")
	testing.expect(t, !ui.submenu_shown(&sub))
}

// On the submenu the pointer selects; a row without a submenu closes the one showing.
@(test)
submenu_hover_selects_on_it_and_closes_for_a_plain_row :: proc(t: ^testing.T) {
	parent: ui.Menu
	parent_build(&parent)
	defer ui.menu_destroy(&parent)
	sub: ui.Submenu
	defer ui.menu_destroy(&sub.menu)
	start := time.tick_now()
	submenu_build(&sub, &parent, 1, false)
	ui.submenu_aim(&sub, &parent, row_center(&parent, 1), start, WIDTH, HEIGHT, SCALE)
	keeps, redraw := ui.submenu_hover(&sub, &parent, row_center(&sub.menu, 2), start, WIDTH, HEIGHT, SCALE)
	testing.expect(t, keeps && redraw)
	testing.expect_value(t, ui.menu_selected(&sub.menu), 2)
	keeps, redraw = ui.submenu_hover(&sub, &parent, row_center(&parent, 0), start, WIDTH, HEIGHT, SCALE)
	testing.expect(t, !keeps && redraw)
	testing.expect(t, !ui.submenu_shown(&sub))
}

// A submenu the pointer opened leaves the keys to its parent except Left, which closes it; one the keyboard
// opened moves and chooses.
@(test)
submenu_keys_follow_how_it_opened :: proc(t: ^testing.T) {
	parent: ui.Menu
	parent_build(&parent)
	defer ui.menu_destroy(&parent)
	sub: ui.Submenu
	defer ui.menu_destroy(&sub.menu)
	testing.expect_value(t, ui.submenu_key(&sub, key(.Arrow_Down)), ui.Submenu_Key.Pass)
	submenu_build(&sub, &parent, 1, false)
	testing.expect_value(t, ui.submenu_key(&sub, key(.Arrow_Down)), ui.Submenu_Key.Pass)
	testing.expect_value(t, ui.submenu_key(&sub, key(.Arrow_Left)), ui.Submenu_Key.Taken)
	testing.expect(t, !ui.submenu_shown(&sub))
	ui.menu_destroy(&sub.menu)
	submenu_build(&sub, &parent, 1, true)
	testing.expect_value(t, ui.submenu_key(&sub, key(.Arrow_Down)), ui.Submenu_Key.Taken)
	testing.expect_value(t, ui.menu_selected(&sub.menu), 1)
	testing.expect_value(t, ui.submenu_key(&sub, key(.Enter)), ui.Submenu_Key.Chosen)
	testing.expect_value(t, ui.submenu_key(&sub, key(.Escape)), ui.Submenu_Key.Taken)
	testing.expect(t, !ui.submenu_shown(&sub))
}

