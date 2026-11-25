package main

import "core:slice"
import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import "cosmos:ui"

DEFAULT_EXPORT_NAME :: "clip.mp4"

@(private = "file")
SETTINGS_WIDTH :: f32(416)
@(private = "file")
SETTINGS_WHEEL_STEP :: f32(48)

@(private = "file")
Settings_Control :: enum u64 {
	Open = 100,
	Dialog,
	File_Name,
	Speed,
	Playhead,
	Done,
	Scrollbar,
	Dismiss_Choices,
	Choice_List,
	First_Choice,
}

@(private = "file")
Setting_Row :: enum {File_Name, Speed, Playhead, Done}

@(private = "file")
SETTINGS_ROWS :: [Setting_Row]Settings_Control{
	.File_Name = .File_Name,
	.Speed = .Speed,
	.Playhead = .Playhead,
	.Done = .Done,
}

// The app owns the settings values and actions. Screen shares the form's layout between input,
// keyboard and assistive technology; Scroll_Viewport owns the scroll, not the form's content.
Settings_Form :: struct {
	screen:            ui.Screen,
	scope:             ui.Focus_Scope,
	viewport:          ui.Scroll_Viewport,
	window, opener:    render.Rect,
	panel, title:      render.Rect,
	content:           render.Rect,
	rows:              [Setting_Row]render.Rect,
	controls:          [Setting_Row]render.Rect,
	choices:           ui.Menu,
	choices_open:      bool,
	file_name:         ui.Text_Field,
	show_playhead:     bool,
}

@(private = "file")
setting_id :: proc(control: Settings_Control) -> ui.Focus_Id {return ui.Focus_Id(control)}

@(private = "file")
choice_id :: proc(index: int) -> ui.Focus_Id {return setting_id(.First_Choice) + ui.Focus_Id(index)}

settings_init :: proc(s: ^Starter) -> bool {
	f := &s.settings
	ui.screen_init(&f.screen)
	ui.menu_init(&f.choices)
	f.show_playhead = true
	f.file_name.bytes = make([dynamic]u8)
	if ui.field_set(&f.file_name, DEFAULT_EXPORT_NAME) != nil {return false}
	for label in SPEED_LABELS {
		if ui.menu_add(&f.choices, {label = label, enabled = true}) != nil {return false}
	}
	settings_layout(s)
	return true
}

settings_destroy :: proc(f: ^Settings_Form) {
	ui.screen_destroy(&f.screen)
	ui.menu_destroy(&f.choices)
	delete(f.file_name.bytes)
}

// Lay out once when geometry, scroll or the semantic values change, not during a draw attempt.
settings_layout :: proc(s: ^Starter, reveal_focus := false) {
	f := &s.settings
	scale := s.scale
	f.window = {0, 0, f32(s.width), f32(s.height)}
	pad := ui.DIALOG_PADDING * scale
	height := ui.HEIGHT_STANDARD * scale
	open_width := ui.SPACE_6 * 4 * scale
	f.opener = {max(pad, f.window.width - pad - open_width), ui.SPACE_2 * scale, open_width, height}
	ui.screen_begin(&f.screen)
	ui.screen_add(&f.screen, {
		id = setting_id(.Open), rect = f.opener, clip = f.window, focusable = true,
		role = .Button, name = "Settings",
	})
	if f.scope == 0 {
		ui.screen_end(&f.screen)
		return
	}

	stack := ui.Stack{axis = .Column, spacing = ui.SPACE_2 * scale, padding = ui.SPACE_1 * scale}
	items := [Setting_Row]ui.Stack_Item{
		.File_Name = {size = height + ui.HEIGHT_COMPACT * scale},
		.Speed = {size = height},
		.Playhead = {size = height},
		.Done = {size = height},
	}
	item_slice := slice.enumerated_array(&items)
	body_height := ui.stack_measure(stack, item_slice)
	header := (ui.DIALOG_PADDING + ui.HEIGHT_TOOLBAR + ui.SPACE_2) * scale
	width := min(SETTINGS_WIDTH * scale, max(0, f.window.width - 2 * pad))
	panel_height := min(body_height + header + pad, max(0, f.window.height - 2 * pad))
	f.panel = {(f.window.width - width) / 2, (f.window.height - panel_height) / 2, width, panel_height}
	inner_width := max(0, width - 2 * pad)
	f.title = {f.panel.x + pad, f.panel.y + pad, inner_width, ui.HEIGHT_TOOLBAR * scale}
	ui.scroll_viewport_layout(&f.viewport, {
		f.panel.x + pad, f.panel.y + header, inner_width, max(0, panel_height - header - pad),
	}, body_height)
	f.content = ui.scroll_viewport_content(f.viewport, scale)
	ui.stack_layout(stack, {0, 0, f.content.width, body_height}, item_slice, slice.enumerated_array(&f.rows))
	if reveal_focus {
		for control, row in SETTINGS_ROWS {
			if setting_id(control) == f.screen.focus.focused {
				r := f.rows[row]
				// Leave room for the focus ring at either edge of the viewport.
				gap := stack.padding
				_ = ui.scroll_viewport_reveal(&f.viewport, {r.x, r.y - gap, r.width, r.height + 2 * gap})
				break
			}
		}
	}
	for r, row in f.rows {f.rows[row] = ui.scroll_viewport_place(f.viewport, r)}
	f.controls = f.rows
	name := &f.controls[.File_Name]
	name.y += name.height - height
	name.height = height
	for row in ([2]Setting_Row{.Speed, .Done}) {
		box := &f.controls[row]
		w := min(box.width / 2, open_width)
		box.x += box.width - w
		box.width = w
	}

	parent := platform.Access_Id(setting_id(.Dialog))
	ui.screen_add(&f.screen, {
		id = setting_id(.Dialog), rect = f.panel, clip = f.window, scope = f.scope,
		role = .Dialog, name = "Settings",
	})
	for control, row in SETTINGS_ROWS {
		region := ui.Screen_Region {
			id = setting_id(control), rect = f.controls[row], clip = f.content,
			scope = f.scope, focusable = true, parent = parent,
		}
		switch row {
		case .File_Name:
			region.role, region.name, region.value = .Text_Field, "Export file name", ui.field_string(&f.file_name)
		case .Speed:
			region.role, region.name = .Combo_Box, "Playback speed"
			region.value = f.choices.items[settings_speed_index(s.speed)].label
			region.state = f.choices_open ? {.Expanded} : {.Collapsed}
		case .Playhead:
			region.role, region.name = .Check_Box, "Show playhead"
			if f.show_playhead {region.state = {.Checked}}
		case .Done:
			region.role, region.name = .Button, "Done"
		}
		ui.screen_add(&f.screen, region)
	}
	if bar, _, visible := ui.scroll_viewport_bar(f.viewport, scale, false); visible {
		ui.screen_add(&f.screen, {id = setting_id(.Scrollbar), rect = bar.track, clip = f.panel, scope = f.scope})
	}
	if f.choices_open {settings_choice_layout(s)}
	ui.screen_end(&f.screen)
}

@(private = "file")
settings_speed_index :: proc(speed: f32) -> int {
	for value, index in SPEEDS {if speed == value {return index}}
	unreachable()
}

@(private = "file")
settings_choice_layout :: proc(s: ^Starter) {
	f := &s.settings
	m := &f.choices
	trigger := f.controls[.Speed]
	m.width = trigger.width / s.scale
	ui.menu_anchor(m, trigger.x, trigger.y + trigger.height + ui.SPACE_1 * s.scale)
	ui.menu_reveal(m, f.window.width, f.window.height, s.scale)
	popup, count := ui.menu_layout(m, f.window.width, f.window.height, s.scale)
	ui.screen_add(&f.screen, {id = setting_id(.Dismiss_Choices), rect = f.window, clip = f.window, scope = f.scope})
	root := setting_id(.Choice_List)
	ui.screen_add(&f.screen, {
		id = root, rect = popup, clip = f.window, scope = f.scope, role = .List,
		name = "Playback speeds", parent = platform.Access_Id(setting_id(.Speed)),
	})
	selected := settings_speed_index(s.speed)
	for index in m.scroll ..< m.scroll + count {
		r := ui.menu_row_rect(m, index, f.window.width, f.window.height, s.scale)
		region := ui.Screen_Region {
			id = choice_id(index), rect = r, clip = render.rect_intersect(popup, f.window), scope = f.scope,
			role = .List_Item, name = m.items[index].label, parent = platform.Access_Id(root),
		}
		if selected == index {region.state = {.Selected}}
		ui.screen_add(&f.screen, region)
	}
}

@(private = "file")
settings_open :: proc(s: ^Starter, keyboard: bool) {
	f := &s.settings
	f.scope = ui.screen_modal_open(&f.screen)
	ui.focus_set(&f.screen.focus, setting_id(.File_Name), keyboard)
	settings_layout(s, reveal_focus = true)
}

@(private = "file")
settings_close :: proc(s: ^Starter) {
	f := &s.settings
	f.choices_open = false
	ui.field_release(&f.file_name)
	ui.scroll_viewport_release(&f.viewport)
	ui.screen_modal_close(&f.screen, f.scope)
	f.scope = 0
	f.viewport.offset = 0
	settings_layout(s)
}

@(private = "file")
settings_choices_toggle :: proc(s: ^Starter, open: bool) {
	f := &s.settings
	if f.choices_open == open {return}
	f.choices_open = open
	if open {
		ui.focus_set(&f.screen.focus, setting_id(.Speed), f.screen.focus.visible)
		selected := settings_speed_index(s.speed)
		for &item, index in f.choices.items {item.checked = index == selected}
		ui.menu_select(&f.choices, selected)
	}
	settings_layout(s, reveal_focus = open)
}

@(private = "file")
settings_activate :: proc(s: ^Starter, id: ui.Focus_Id, keyboard: bool) {
	f := &s.settings
	switch id {
	case setting_id(.Open): settings_open(s, keyboard)
	case setting_id(.Speed): settings_choices_toggle(s, !f.choices_open)
	case setting_id(.Playhead):
		f.show_playhead = !f.show_playhead
		settings_layout(s)
	case setting_id(.Done): settings_close(s)
	case setting_id(.Dismiss_Choices): settings_choices_toggle(s, false)
	case:
		if id >= choice_id(0) && id < choice_id(len(SPEEDS)) {
			speeds := SPEEDS
			s.speed = speeds[int(id - choice_id(0))]
			settings_choices_toggle(s, false)
		}
	}
}

@(private = "file")
settings_field_box :: proc(s: ^Starter) -> ui.Field_Box {
	return ui.field_box_standard(&s.settings.file_name, &s.text, s.settings.controls[.File_Name], s.scale)
}

@(private = "file")
settings_field_key :: proc(s: ^Starter, e: input.Key_Event) {
	field := &s.settings.file_name
	if .Control in e.modifiers && .Alt not_in e.modifiers {
		#partial switch e.key {
		case .C, .X:
			selected := ui.field_selected_text(field)
			if selected != "" && platform.clipboard_set_text(&s.desktop, selected) && e.key == .X {
				_ = ui.field_text(field, "")
				settings_layout(s)
			}
			return
		case .V:
			if value, ok := platform.clipboard_get_text(&s.desktop, context.temp_allocator); ok && ui.field_text(field, value) == .Edited {
				settings_layout(s)
			}
			return
		}
	}
	#partial switch e.key {
	case .Home, .End, .Arrow_Left, .Arrow_Right, .Backspace, .Delete:
	case:
		select_all := e.key == .A && .Control in e.modifiers && .Alt not_in e.modifiers
		if !select_all && (e.text == "" || e.text[0] < ' ' || e.text[0] == 0x7f) {return}
	}
	if ui.field_key(field, e) == .Edited {settings_layout(s)}
}

@(private = "file")
settings_key :: proc(s: ^Starter, e: input.Key_Event) -> bool {
	f := &s.settings
	modal := f.scope != 0
	if !e.pressed {return modal}
	if ui.focus_key(&f.screen.focus, e) {
		f.choices_open = false
		settings_layout(s, reveal_focus = true)
		return true
	}
	if f.choices_open {
		switch ui.menu_key(&f.choices, e) {
		case .Changed: settings_layout(s)
		case .Chosen: settings_activate(s, choice_id(ui.menu_selected(&f.choices)), true)
		case .Closed: settings_choices_toggle(s, false)
		case .None, .Submenu:
		}
		return true
	}
	if modal && e.key == .Escape && !e.repeat {
		settings_close(s)
		return true
	}
	if modal && f.screen.focus.focused == setting_id(.File_Name) {
		// Do not replace a text selection with the control characters produced by Enter or Escape.
		if e.key != .Enter && e.key != .Numpad_Enter && e.key != .Escape {settings_field_key(s, e)}
		return true
	}
	if e.modifiers == {} && !e.repeat && (e.key == .Enter || e.key == .Numpad_Enter || e.key == .Space || e.key == .Arrow_Down && f.screen.focus.focused == setting_id(.Speed)) {
		id := f.screen.focus.focused
		if id != 0 {
			settings_activate(s, id, true)
			return true
		}
	}
	return modal
}

// This is the single screen-level dispatch. Pointer order, capture and Tab are not app policy;
// the cases here connect those interactions to the values and actions this sample owns.
settings_event :: proc(s: ^Starter, event: platform.Event) -> bool {
	f := &s.settings
	if s.menu.shown {return false}
	modal := f.scope != 0
	#partial switch e in event {
	case input.Mouse_Move_Event:
		s.pointer = {f32(e.x), f32(e.y)}
		ui.screen_move(&f.screen, s.pointer)
		if ui.scroll_viewport_drag(&f.viewport, s.pointer.y, s.scale) {settings_layout(s)}
		if f.file_name.dragging {
			at := ui.field_box_offset(settings_field_box(s), s.pointer.x)
			_ = ui.field_pointer(&f.file_name, at, false, true)
		}
		if f.choices_open {
			id := ui.screen_pick(&f.screen, s.pointer)
			if id >= choice_id(0) && id < choice_id(len(SPEEDS)) {
				index := int(id - choice_id(0))
				if ui.menu_selected(&f.choices) != index {
					ui.menu_select(&f.choices, index)
					settings_layout(s)
				}
			}
		}
		shape: platform.Cursor_Shape = .Arrow
		if f.file_name.dragging || ui.screen_hovered(&f.screen, setting_id(.File_Name)) {shape = .Text}
		_ = platform.window_set_cursor(&s.desktop, s.window, shape)
		return true
	case input.Mouse_Button_Event:
		s.pointer = {f32(e.x), f32(e.y)}
		id, activate := ui.screen_button(&f.screen, e)
		if e.button == .Left {
			if e.pressed {
				if id == setting_id(.File_Name) {
					at := ui.field_box_offset(settings_field_box(s), s.pointer.x)
					_ = ui.field_press(&f.file_name, at, s.pointer.x, .Shift in e.modifiers, e.time_ns)
				} else if id == setting_id(.Scrollbar) && ui.scroll_viewport_press(&f.viewport, s.pointer, s.scale) {
					settings_layout(s)
				}
			} else {
				ui.field_release(&f.file_name)
				ui.scroll_viewport_release(&f.viewport)
				if activate {settings_activate(s, id, false)}
			}
		}
		return modal || id != 0
	case input.Mouse_Wheel_Event:
		if modal && !f.choices_open && ui.scroll_viewport_wheel(&f.viewport, e, SETTINGS_WHEEL_STEP * s.scale) {settings_layout(s)}
		return modal
	case input.Key_Event:
		return settings_key(s, e)
	case input.Text_Event:
		if modal && f.screen.focus.focused == setting_id(.File_Name) && ui.field_text(&f.file_name, e.text) == .Edited {settings_layout(s)}
		return modal
	case platform.Mouse_Leave_Event:
		ui.screen_leave(&f.screen)
	case platform.Focus_Event:
		if !e.focused {
			ui.screen_cancel(&f.screen)
			ui.screen_leave(&f.screen)
			ui.field_release(&f.file_name)
			ui.scroll_viewport_release(&f.viewport)
		}
	case platform.Capture_Lost_Event:
		ui.screen_cancel(&f.screen)
		ui.field_release(&f.file_name)
		ui.scroll_viewport_release(&f.viewport)
	case platform.Access_Invoke_Event:
		if e.window != s.window {return false}
		id := ui.screen_access_target(&f.screen, e)
		if id == setting_id(.Speed) {
			settings_choices_toggle(s, e.action == .Expand)
		} else if id != 0 {
			if id == setting_id(.Open) {ui.focus_set(&f.screen.focus, id, true)}
			if !f.choices_open || id >= choice_id(0) {settings_activate(s, id, true)}
		}
		return modal || id != 0
	case platform.Access_Focus_Event:
		if e.window == s.window && ui.access_focus_request(&f.screen.focus, e) {
			if f.screen.focus.focused != setting_id(.Speed) {f.choices_open = false}
			settings_layout(s, reveal_focus = true)
			return true
		}
		return modal
	}
	return false
}

@(private = "file")
settings_label :: proc(s: ^Starter, r: render.Rect, label: string, style := ui.Text_Style.Body) -> render.Build_Status {
	if r.width <= 0 || r.height <= 0 {return .Ok}
	t := ui.text_styled(&s.text, style)
	baseline := r.y + (r.height - t.line_height) / 2 + t.ascent
	return ui.draw_text(&t, &s.list, label, r.x, baseline, s.theme.text, r.width)
}

settings_draw :: proc(s: ^Starter) -> render.Build_Status {
	f := &s.settings
	scale := s.scale
	open_focus := ui.focus_visible(f.screen.focus, setting_id(.Open)) && f.scope == 0 && !s.menu.shown
	pointer := [2]f32{-1, -1}
	if !s.menu.shown && ui.screen_hovered(&f.screen, setting_id(.Open)) {pointer = s.pointer}
	if status := ui.text_button_draw(&s.list, &s.text, s.theme, f.opener, "Settings", open_focus, scale, pointer); status != .Ok {return status}
	if f.scope == 0 {return .Ok}
	if render.push_layer(&s.list, f.window) != .None {return .Ok}
	ui.draw_rect(&s.list, {rect = f.window, color = s.theme.scrim})
	if ui.panel_draw(&s.list, ui.dialog_panel(f.panel, scale), s.theme) != .None {return .Ok}
	if result := settings_panel_draw(s); result != .Ok {return result}
	if f.choices_open {return ui.menu_draw(&f.choices, &s.list, &s.text, s.theme, f.window.width, f.window.height, scale, s.pointer)}
	return .Ok
}

@(private = "file")
settings_panel_draw :: proc(s: ^Starter) -> render.Build_Status {
	f := &s.settings
	panel_clip, err := render.clip_push(&s.list, f.panel)
	if err != .None {return .Ok}
	defer _ = render.clip_pop(&s.list, panel_clip)
	if res := settings_label(s, f.title, "Settings", .Title); res != .Ok {return res}
	if f.content.height <= 0 {return .Ok}
	if res := settings_rows_draw(s); res != .Ok {return res}
	hovered := ui.screen_hovered(&f.screen, setting_id(.Scrollbar))
	if bar, state, visible := ui.scroll_viewport_bar(f.viewport, s.scale, hovered); visible {
		ui.scrollbar_draw(&s.list, s.theme, bar, state)
	}
	return .Ok
}

@(private = "file")
settings_rows_draw :: proc(s: ^Starter) -> render.Build_Status {
	f := &s.settings
	scale := s.scale
	clip, err := render.clip_push(&s.list, f.content)
	if err != .None {return .Ok}
	defer _ = render.clip_pop(&s.list, clip)
	for control, row in SETTINGS_ROWS {
		r, box := f.rows[row], f.controls[row]
		visible := render.rect_intersect(r, f.content)
		if visible.height <= 0 || visible.width <= 0 {continue}
		id := setting_id(control)
		focused := ui.focus_visible(f.screen.focus, id)
		// Non-owning controls must not paint pointer hover through the dropdown's hit shield.
		pointer := [2]f32{-1, -1}
		if ui.screen_hovered(&f.screen, id) {pointer = s.pointer}
		switch row {
		case .File_Name:
			label := render.Rect{r.x, r.y, r.width, r.height - box.height}
			if status := settings_label(s, label, "Export file name"); status != .Ok {return status}
			ui.box_draw(&s.list, box, s.theme, focused, scale)
			field := settings_field_box(s)
			active := f.screen.focus.focused == id
			if status := ui.field_box_draw(field, &s.list, s.theme, ui.field_box_baseline(field), active, DEFAULT_EXPORT_NAME); status != .Ok {return status}
		case .Speed:
			label := render.Rect{r.x, r.y, max(0, box.x - r.x - ui.SPACE_2 * scale), r.height}
			if status := settings_label(s, label, "Playback speed"); status != .Ok {return status}
			value := f.choices.items[settings_speed_index(s.speed)].label
			if status := ui.text_button_draw(&s.list, &s.text, s.theme, box, value, focused, scale, pointer); status != .Ok {return status}
			arrow := ui.ICON_INDICATOR * scale
			arrow_box := render.Rect{box.x + box.width - arrow - ui.CONTROL_INSET * scale, box.y + (box.height - arrow) / 2, arrow, arrow}
			if box.width >= ui.SPACE_6 * 3 * scale {
				ui.icon_draw(&s.list, .Chevron_Down, arrow_box, s.theme.muted, ui.ICON_INDICATOR, scale)
			}
		case .Playhead:
			w, h := ui.SWITCH_WIDTH * scale, ui.SWITCH_HEIGHT * scale
			track := render.Rect{box.x + max(0, box.width - w), box.y + (box.height - h) / 2, min(w, box.width), h}
			label := render.Rect{r.x, r.y, max(0, track.x - r.x - ui.SPACE_2 * scale), r.height}
			if status := settings_label(s, label, "Show playhead"); status != .Ok {return status}
			ui.switch_draw(&s.list, track, f.show_playhead, focused, s.theme, scale)
		case .Done:
			hover, press := f32(0), f32(0)
			if ui.screen_hovered(&f.screen, id) {hover = 1}
			if ui.screen_pressed(&f.screen, id) {press = 1}
			if status := ui.primary_button_draw(&s.list, &s.text, s.theme, box, "Done", hover, press, focused, scale, pointer); status != .Ok {return status}
		}
	}
	return .Ok
}
