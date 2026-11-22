package ui

import "cosmos:input"
import "cosmos:render"
import "core:time"

// How long the pointer rests on a row before its submenu shows, Radix UI's open delay, so a sweep down the
// menu does not flash each submenu it crosses. The keyboard opens one at once.
SUBMENU_DELAY :: 100 * time.Millisecond

// A menu of a row's own, shown beside the row of the menu it hangs from. The owner keeps which menu that is
// and builds the rows; this keeps which row it hangs from, the open delay and menu aim. `width`, `height`
// and `scale` below are the window's.
Submenu :: struct {
	using menu:    Menu,
	// The parent row it hangs from while it shows.
	row:           Maybe(int),
	// Keeps it while the pointer heads from its row to it (menu aim).
	reveal:        Hover_Reveal,
	// A row the pointer rests on whose submenu shows SUBMENU_DELAY after `pending_since`.
	pending_row:   Maybe(int),
	pending_since: time.Tick,
}

// What the submenu did with a key.
Submenu_Key :: enum u8 {
	// The key is the parent's.
	Pass,
	// The submenu took it; the window redraws.
	Taken,
	// The selected row was chosen.
	Chosen,
}

submenu_shown :: proc(sub: ^Submenu) -> bool {
	_, shown := sub.row.?
	return shown
}

// Hides it and forgets a row waiting for its own. True when it showed, so the window redraws.
submenu_close :: proc(sub: ^Submenu) -> bool {
	shown := sub.row != nil
	sub.row, sub.pending_row = nil, nil
	hover_reveal_close(&sub.reveal)
	return shown
}

// Hangs the rows just built beside row `row` of `parent`, `menu_width` DIPs wide, with the first selected
// for the keyboard.
submenu_place :: proc(
	sub: ^Submenu,
	parent: ^Menu,
	row: int,
	menu_width: f32,
	select_first: bool,
	width, height, scale: f32,
) {
	sub.width = menu_width
	anchor := menu_submenu_anchor(parent, row, menu_width, width, height, scale)
	menu_anchor(&sub.menu, anchor.x, anchor.y)
	menu_select(&sub.menu, select_first ? 0 : -1)
	sub.row = row
}

// The row whose submenu is due: the pointer, at `point`, has rested on it for SUBMENU_DELAY. The owner
// builds and places that submenu, then calls submenu_aim.
submenu_due :: proc(
	sub: ^Submenu,
	parent: ^Menu,
	point: [2]f32,
	now: time.Tick,
	width, height, scale: f32,
) -> (
	row: int,
	due: bool,
) {
	pending: bool
	row, pending = sub.pending_row.?
	if !pending || time.tick_diff(time.tick_add(sub.pending_since, SUBMENU_DELAY), now) < 0 {return 0, false}
	sub.pending_row = nil
	if menu_hit(parent, point.x, point.y, width, height, scale) != row {return 0, false}
	return row, true
}

// Starts menu aim from `point`, on the row whose submenu the pointer just opened.
submenu_aim :: proc(sub: ^Submenu, parent: ^Menu, point: [2]f32, now: time.Tick, width, height, scale: f32) {
	row, shown := sub.row.?
	if !shown {return}
	trigger := menu_row_rect(parent, row, width, height, scale)
	surface, _ := menu_layout(&sub.menu, width, height, scale)
	hover_reveal_move(&sub.reveal, point, true, false, false, trigger, surface, HOVER_AIM_SLACK * scale, now)
}

// Closes the submenu once an aim at it stopped short. True when it did: the owner redraws and gives the row
// under the pointer its turn.
submenu_tick :: proc(sub: ^Submenu, now: time.Tick) -> bool {
	if !hover_reveal_tick(&sub.reveal, now) {return false}
	_ = submenu_close(sub)
	return true
}

submenu_deadline :: proc(sub: ^Submenu) -> (time.Tick, bool) {
	if _, pending := sub.pending_row.?; pending {return time.tick_add(sub.pending_since, SUBMENU_DELAY), true}
	return hover_reveal_deadline(sub.reveal)
}

// The submenu's keys while it shows with a row selected: it moves and chooses, and Left or Escape closes it.
// A submenu the pointer opened has no selection yet, so the keys stay with the highlighted row of the menu it
// hangs from, as in Radix UI, except that Left still closes it.
submenu_key :: proc(sub: ^Submenu, logical: input.Key_Event) -> Submenu_Key {
	if !submenu_shown(sub) {return .Pass}
	if menu_selected(&sub.menu) < 0 {
		if logical.key != .Arrow_Left {return .Pass}
		_ = submenu_close(sub)
		return .Taken
	}
	switch menu_key(&sub.menu, logical) {
	case .None, .Submenu:
		if logical.key == .Arrow_Left {_ = submenu_close(sub)}
	case .Changed:
	case .Chosen:
		return .Chosen
	case .Closed:
		_ = submenu_close(sub)
	}
	return .Taken
}

// The pointer at `point` over the submenu or `parent`, the menu it hangs from. On the submenu it selects
// there. While the pointer heads from a row to its submenu (Hover_Reveal) everything stays as it is;
// otherwise the parent row under the pointer waits SUBMENU_DELAY for its submenu, which submenu_due then
// gives, or, having none, closes the one showing. `keeps` is true when the submenu keeps the pointer.
submenu_hover :: proc(
	sub: ^Submenu,
	parent: ^Menu,
	point: [2]f32,
	now: time.Tick,
	width, height, scale: f32,
) -> (
	keeps: bool,
	redraw: bool,
) {
	slack := HOVER_AIM_SLACK * scale
	hit := menu_hit(parent, point.x, point.y, width, height, scale)
	if row, shown := sub.row.?; shown {
		trigger := menu_row_rect(parent, row, width, height, scale)
		surface, _ := menu_layout(&sub.menu, width, height, scale)
		on_trigger := render.rect_contains(trigger, point.x, point.y)
		on_surface := render.rect_contains(surface, point.x, point.y)
		// Another row of the menu wants the hover unless the pointer is heading for the submenu.
		on_other := !on_trigger && !on_surface && hit >= 0 && hit != row
		hover_reveal_move(&sub.reveal, point, on_trigger, on_surface, on_other, trigger, surface, slack, now)
		if on_surface {
			place := menu_hit(&sub.menu, point.x, point.y, width, height, scale)
			if place >= 0 && place != menu_selected(&sub.menu) {
				menu_select(&sub.menu, place)
				redraw = true
			}
			return true, redraw
		}
		if sub.reveal.open && !on_trigger {return true, false}
	}
	if hit < 0 {
		sub.pending_row = nil
		return false, false
	}
	if !parent.items[hit].submenu {return false, submenu_close(sub)}
	if current, showing := sub.row.?; showing && current == hit {
		trigger := menu_row_rect(parent, hit, width, height, scale)
		surface, _ := menu_layout(&sub.menu, width, height, scale)
		hover_reveal_move(&sub.reveal, point, true, false, false, trigger, surface, slack, now)
		return false, false
	}
	if sub.row != nil {redraw = submenu_close(sub)}
	if pending, waiting := sub.pending_row.?; !waiting || pending != hit {
		sub.pending_row, sub.pending_since = hit, now
	}
	return false, redraw
}
