package main

import "core:fmt"
import "core:time"
import "cosmos:input"
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

// The playback speeds the Speed submenu offers; a row's payload is its index.
SPEEDS :: [?]f32{0.5, 1, 2}
// The submenu's width in DIPs.
SPEED_MENU_WIDTH :: 160

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
	add :: proc(m: ^ui.Menu, item: ui.Menu_Item) {_, _ = ui.menu_add(m, item)}
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
	speeds := SPEEDS
	for speed, i in speeds {
		label := fmt.tprintf("%g×", speed)
		_, _ = ui.menu_add(&sub.menu, {label = label, enabled = true, checked = speed == s.speed, payload = u32(i)})
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
