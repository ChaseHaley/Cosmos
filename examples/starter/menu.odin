package main

import "core:time"
import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import "cosmos:ui"

// What a menu row does: its payload.
Menu_Action :: enum u32 {
	None,
	Open,
	Export,
	Speed,
	Quit,
}

// The playback speeds the Speed submenu offers, and their rows' labels; a row's payload is its index. The
// labels are constants because the menu keeps them across ticks, which free their temporary memory.
SPEEDS :: [?]f32{0.5, 1, 2}
SPEED_LABELS :: [len(SPEEDS)]string{"0.5×", "1×", "2×"}
// The submenu's width in DIPs.
SPEED_MENU_WIDTH :: 160
// The menus' nodes in the window's accessibility tree.
MENU_ACCESS :: platform.Access_Id(2)
SPEED_ACCESS :: platform.Access_Id(3)

// The right-click menu over the viewer, with its Playback speed submenu, which opens after the pointer
// rests on its row (ui.SUBMENU_DELAY) and stays while the pointer heads for it.
Context_Menu :: struct {
	menu:    ui.Menu,
	shown:   bool,
	submenu: ui.Submenu,
}

menu_init :: proc(m: ^Context_Menu) {
	ui.menu_init(&m.menu)
	ui.menu_init(&m.submenu.menu)
}

menu_destroy :: proc(m: ^Context_Menu) {
	ui.menu_destroy(&m.menu)
	ui.menu_destroy(&m.submenu.menu)
}

// Shows the menu with its top left at `point`.
menu_open :: proc(s: ^Starter, point: [2]f32) {
	m := &s.menu
	ui.menu_clear(&m.menu)
	add :: proc(m: ^ui.Menu, item: ui.Menu_Item) {_ = ui.menu_add(m, item)}
	add(&m.menu, {label = "Open videos…", shortcut = "Ctrl+O", enabled = true, payload = u32(Menu_Action.Open)})
	add(&m.menu, {label = "Export clip…", shortcut = "Ctrl+S", enabled = true, payload = u32(Menu_Action.Export)})
	add(&m.menu, {separator = true})
	add(&m.menu, {label = "Playback speed", enabled = true, submenu = true, payload = u32(Menu_Action.Speed)})
	add(&m.menu, {separator = true})
	add(&m.menu, {label = "Quit", enabled = true, payload = u32(Menu_Action.Quit)})
	ui.menu_anchor(&m.menu, point.x, point.y)
	ui.menu_select(&m.menu, -1)
	_ = ui.submenu_close(&m.submenu)
	m.shown = true
}

menu_close :: proc(s: ^Starter) {
	s.menu.shown = false
	_ = ui.submenu_close(&s.menu.submenu)
}

// Builds the speed rows into the submenu and hangs it beside row `row`.
@(private = "file")
speed_open :: proc(s: ^Starter, row: int, select_first: bool) {
	sub := &s.menu.submenu
	ui.menu_clear(&sub.menu)
	speeds, labels := SPEEDS, SPEED_LABELS
	for speed, i in speeds {
		item := ui.Menu_Item {
			label   = labels[i],
			enabled = true,
			checked = speed == s.speed,
			payload = u32(i),
		}
		_ = ui.menu_add(&sub.menu, item)
	}
	ui.submenu_place(sub, &s.menu.menu, row, SPEED_MENU_WIDTH, select_first, f32(s.width), f32(s.height), s.scale)
}

// Opens the submenu the pointer has rested on long enough, and closes one an aim stopped short of.
menu_tick :: proc(s: ^Starter, now: time.Tick) {
	if !s.menu.shown {return}
	width, height := f32(s.width), f32(s.height)
	sub := &s.menu.submenu
	if row, due := ui.submenu_due(sub, &s.menu.menu, s.pointer, now, width, height, s.scale); due {
		speed_open(s, row, false)
		ui.submenu_aim(sub, &s.menu.menu, s.pointer, now, width, height, s.scale)
		return
	}
	_ = ui.submenu_tick(sub, now)
}

// The pointer moved over the menu: the submenu keeps it while it heads there, and the row under it is
// selected.
menu_hover :: proc(s: ^Starter, point: [2]f32, now: time.Tick) {
	if !s.menu.shown {return}
	width, height := f32(s.width), f32(s.height)
	keeps, _ := ui.submenu_hover(&s.menu.submenu, &s.menu.menu, point, now, width, height, s.scale)
	if keeps {return}
	ui.menu_select(&s.menu.menu, ui.menu_hit(&s.menu.menu, point.x, point.y, width, height, s.scale))
}

// A press while the menu shows: a row chooses, anywhere else closes the menu. True when the menu took it.
menu_press :: proc(s: ^Starter, e: input.Mouse_Button_Event) -> bool {
	if !s.menu.shown {return false}
	width, height := f32(s.width), f32(s.height)
	x, y := f32(e.x), f32(e.y)
	sub := &s.menu.submenu
	if ui.submenu_shown(sub) {
		if row := ui.menu_hit(&sub.menu, x, y, width, height, s.scale); row >= 0 {
			speed_choose(s, row)
			return true
		}
	}
	row := ui.menu_hit(&s.menu.menu, x, y, width, height, s.scale)
	if row < 0 {
		menu_close(s)
		return true
	}
	menu_choose(s, row)
	return true
}

// The menu's keys while it shows: the submenu's first, then the menu's own; Right on Playback speed opens
// the submenu at once. True when the menu took the key.
menu_key :: proc(s: ^Starter, e: input.Key_Event) -> bool {
	if !s.menu.shown {return false}
	sub := &s.menu.submenu
	switch ui.submenu_key(sub, e) {
	case .Taken:
		return true
	case .Chosen:
		speed_choose(s, ui.menu_selected(&sub.menu))
		return true
	case .Pass:
	}
	switch ui.menu_key(&s.menu.menu, e) {
	case .None:
		return false
	case .Changed:
	case .Chosen:
		menu_choose(s, ui.menu_selected(&s.menu.menu))
	case .Closed:
		menu_close(s)
	case .Submenu:
		speed_open(s, ui.menu_selected(&s.menu.menu), true)
	}
	return true
}

@(private = "file")
menu_choose :: proc(s: ^Starter, row: int) {
	item := s.menu.menu.items[row]
	if !item.enabled || item.separator {return}
	switch Menu_Action(item.payload) {
	case .None:
	case .Open:
		menu_close(s)
		starter_open_videos(s)
	case .Export:
		menu_close(s)
		starter_export(s)
	case .Speed:
		speed_open(s, row, true)
	case .Quit:
		menu_close(s)
		starter_quit(s)
	}
}

@(private = "file")
speed_choose :: proc(s: ^Starter, row: int) {
	speeds := SPEEDS
	if row >= 0 && row < len(speeds) {s.speed = speeds[row]}
	menu_close(s)
}

// Draws the menu and its submenu over everything else.
menu_draw :: proc(s: ^Starter) -> render.Build_Status {
	if !s.menu.shown {return .Ok}
	width, height := f32(s.width), f32(s.height)
	if status := ui.menu_draw(&s.menu.menu, &s.list, &s.text, s.theme, width, height, s.scale, s.pointer);
	   status != .Ok {
		return status
	}
	if !ui.submenu_shown(&s.menu.submenu) {return .Ok}
	return ui.menu_draw(&s.menu.submenu.menu, &s.list, &s.text, s.theme, width, height, s.scale, s.pointer)
}

// Adds the menus while they show and returns the focus: the submenu's selected row, else the menu's.
menu_access :: proc(s: ^Starter) -> platform.Access_Id {
	if !s.menu.shown {return 0}
	width, height := f32(s.width), f32(s.height)
	sub := &s.menu.submenu
	ui.menu_access(&s.menu.menu, &s.access, 0, MENU_ACCESS, "Context menu", width, height, s.scale, sub.row)
	ui.submenu_access(sub, &s.access, MENU_ACCESS, SPEED_ACCESS, "Playback speed", width, height, s.scale)
	if ui.submenu_shown(sub) {
		if focus := row_access(&sub.menu, SPEED_ACCESS); focus != 0 {return focus}
	}
	return row_access(&s.menu.menu, MENU_ACCESS)
}

// The selected row's node; a selected separator, which the pointer can rest on, has none.
@(private = "file")
row_access :: proc(m: ^ui.Menu, base: platform.Access_Id) -> platform.Access_Id {
	row := ui.menu_selected(m)
	if row < 0 || m.items[row].separator {return 0}
	return ui.access_part(base, u64(row))
}

// A screen reader's action on a menu row: Invoke chooses it as a click does, and Expand and Collapse open
// and close the submenu of Playback speed, as Right and Left do.
menu_access_invoke :: proc(s: ^Starter, e: platform.Access_Invoke_Event) {
	if !s.menu.shown {return}
	sub := &s.menu.submenu
	if row, ok := ui.menu_access_row(&sub.menu, SPEED_ACCESS, e.id); ok && ui.submenu_shown(sub) {
		if e.action == .Invoke {speed_choose(s, row)}
		return
	}
	row, ok := ui.menu_access_row(&s.menu.menu, MENU_ACCESS, e.id)
	if !ok {return}
	item := s.menu.menu.items[row]
	switch e.action {
	case .Invoke:
		menu_choose(s, row)
	case .Expand:
		if !item.submenu {return}
		ui.menu_select(&s.menu.menu, row)
		menu_choose(s, row)
	case .Collapse:
		if open, shown := sub.row.?; shown && open == row {
			_ = ui.submenu_close(sub)
			ui.menu_select(&s.menu.menu, row)
		}
	case .Toggle:
	}
}

// A screen reader moved focus to a menu row, which is selected as the arrow keys would. A row of the menu
// other than the one the submenu hangs from closes the submenu; that row takes focus back from it.
menu_access_focus :: proc(s: ^Starter, id: platform.Access_Id) {
	if !s.menu.shown {return}
	sub := &s.menu.submenu
	if row, ok := ui.menu_access_row(&sub.menu, SPEED_ACCESS, id); ok && ui.submenu_shown(sub) {
		ui.menu_select(&sub.menu, row)
		return
	}
	row, ok := ui.menu_access_row(&s.menu.menu, MENU_ACCESS, id)
	if !ok {return}
	ui.menu_select(&s.menu.menu, row)
	if open, shown := sub.row.?; shown && open == row {
		ui.menu_select(&sub.menu, -1)
	} else {
		_ = ui.submenu_close(sub)
	}
}
