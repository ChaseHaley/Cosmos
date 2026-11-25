package ui

import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import "cosmos:search"
import "core:strings"

@(private) FIND_WIDTH :: 440
@(private) FIND_HEIGHT :: 40
@(private) FIND_MARGIN :: 12
@(private) FIND_PADDING :: 12
@(private) FIND_TOGGLE :: 28

Find_Bar :: struct {
	// Only the procedures in this file write it.
	state:   Find_State,
	query:   Text_Field,
	options: search.Options,
	hover:   Find_Button,
	armed:   Armed(Find_Button),
	motion:  [Find_Button]Control_Motion,
}

// nil is closed. The bar stays open without the keyboard after a click elsewhere, so the terminal takes
// keys while matches stay highlighted.
Find_State :: union {
	Find_Editing,
	Find_Browsing,
	Find_Blurred,
}

Find_Editing :: struct {}

// Up and Down step through history like a shell prompt.
Find_Browsing :: Query_Browse(search.Options)

Find_Blurred :: struct {}

Find_Entry :: Query_Entry(search.Options)

// Searches shared by every window, oldest first.
Find_History :: Query_History(search.Options)

Find_Layout :: struct { panel, query, case_toggle, regex_toggle, status, up, down, close: render.Rect }

// What a key, text or click did to the bar.
Find_Outcome :: union #no_nil {Find_Change, search.Step}

Find_Change :: enum {
	None,
	Changed,
	Moved,
	Closed,
}

// The bar's buttons, the pointer targets a press arms and a release activates.
Find_Button :: enum {
	None,
	Up,
	Down,
	Close,
	Case_Toggle,
	Regex_Toggle,
}

// The key that does what each button does while the bar has the keyboard. find_key reads them through
// find_key_button and the buttons' tooltips name them, so a change here reaches both.
@(rodata)
FIND_KEYS := #partial [Find_Button]input.Shortcut {
	.Up           = {.Enter, {.Shift}},
	.Down         = {.Enter, {}},
	.Close        = {.Escape, {}},
	.Case_Toggle  = {.C, {.Alt}},
	.Regex_Toggle = {.R, {.Alt}},
}

// The button a key presses: Numpad Enter counts as Enter, an Alt key needs Alt without Control (AltGr
// types), and Shift picks between the buttons that share a key; other modifiers do not matter.
@(private)
find_key_button :: proc(e: input.Key_Event) -> Find_Button {
	key := e.key == .Numpad_Enter ? input.Key.Enter : e.key
	alt := .Alt in e.modifiers && .Control not_in e.modifiers
	found := Find_Button.None
	for shortcut, button in FIND_KEYS {
		if button == .None || shortcut.key != key {continue}
		if .Alt in shortcut.modifiers {
			if alt {return button}
			continue
		}
		if (.Shift in shortcut.modifiers) == (.Shift in e.modifiers) {return button}
		if found == .None {found = button}
	}
	return found
}

find_init :: proc(f: ^Find_Bar, allocator := context.allocator) {
	f.query.bytes = make([dynamic]u8, allocator)
}

find_destroy :: proc(f: ^Find_Bar) {
	find_enter(f, nil)
	delete(f.query.bytes)
	f^ = {}
}

find_is_open :: proc(f: ^Find_Bar) -> bool { return f.state != nil }

// Whether keys and text belong to the find bar rather than the terminal.
find_has_keyboard :: proc(f: ^Find_Bar) -> bool {
	switch _ in f.state {
	case Find_Editing, Find_Browsing:
		return true
	case Find_Blurred:
	}
	return false
}

// Every change of state goes through here, so leaving history browsing always frees its draft.
@(private)
find_enter :: proc(f: ^Find_Bar, to: Find_State) {
	if browsing, ok := f.state.(Find_Browsing); ok {delete(browsing.draft.query)}
	f.state = to
}

// Records the query as the newest search, moving an earlier copy of it.
find_history_add :: proc(h: ^Find_History, f: ^Find_Bar) {
	query_history_add(h, field_string(&f.query), f.options)
}

// Opens with the keyboard. `restore` refills the newest search, and `select` also selects it so typing
// replaces it.
find_open :: proc(f: ^Find_Bar, h: ^Find_History = nil, restore := false, select := false) {
	find_enter(f, Find_Editing{})
	f.hover = .None
	f.motion = {}
	armed_cancel(&f.armed)
	newest, found := query_history_newest(h)
	field_set(&f.query, (restore || select) && found ? newest.query : "")
	if select { field_select_all(&f.query) }
}

// Gives the open bar the keyboard again, selecting the query when `select` is set. A closed bar stays closed.
find_focus :: proc(f: ^Find_Bar, select := false) {
	if f.state == nil { return }
	if _, blurred := f.state.(Find_Blurred); blurred { find_enter(f, Find_Editing{}) }
	if select { field_select_all(&f.query) }
}

// Leaves the bar and its matches showing while the terminal takes the keyboard.
find_blur :: proc(f: ^Find_Bar, h: ^Find_History = nil) {
	if !find_has_keyboard(f) { return }
	find_history_add(h, f)
	find_enter(f, Find_Blurred{})
	armed_cancel(&f.armed)
}

find_close :: proc(f: ^Find_Bar, h: ^Find_History = nil) {
	if f.state != nil { find_history_add(h, f) }
	find_enter(f, nil)
	f.hover = .None
	f.motion = {}
	armed_cancel(&f.armed)
}

// Typing or Enter ends history browsing; the query keeps what browsing put there.
@(private)
find_edit :: proc(f: ^Find_Bar) {
	if _, browsing := f.state.(Find_Browsing); browsing { find_enter(f, Find_Editing{}) }
}

// Handles a key while the bar has the keyboard: FIND_KEYS press the buttons, and Up and Down browse
// earlier searches.
find_key :: proc(f: ^Find_Bar, e: input.Key_Event, h: ^Find_History = nil) -> Find_Outcome {
	if !e.pressed {
		return Find_Change.None
	}
	switch button := find_key_button(e); button {
	case .Close:
		return Find_Change.Closed
	case .Up, .Down:
		find_history_add(h, f)
		find_edit(f)
		return button == .Up ? search.Step.Previous : search.Step.Next
	case .Case_Toggle, .Regex_Toggle:
		return find_toggle(f, button)
	case .None:
	}
	#partial switch e.key {
	case .Arrow_Up:
		return find_recall(f, h, true)
	case .Arrow_Down:
		return find_recall(f, h, false)
	}
	outcome := find_change(field_key(&f.query, e))
	if outcome == Find_Change.Changed { find_edit(f) }
	return outcome
}

@(private)
find_toggle :: proc(f: ^Find_Bar, target: Find_Button) -> Find_Change {
	#partial switch target {
	case .Case_Toggle:
		f.options.case_sensitive = !f.options.case_sensitive
	case .Regex_Toggle:
		f.options.regex = !f.options.regex
	case:
		return Find_Change.None
	}
	return Find_Change.Changed
}

// Steps through history like a shell prompt; stepping past the newest entry restores the draft and ends
// browsing.
@(private)
find_recall :: proc(f: ^Find_Bar, h: ^Find_History, older: bool) -> Find_Change {
	browsing, is_browsing := &f.state.(Find_Browsing)
	next, ok := query_history_step(h, is_browsing ? browsing.index : -1, field_string(&f.query), older)
	switch {
	case !ok:
		return Find_Change.None
	case next < 0:
		find_show(f, browsing.draft)
		find_enter(f, Find_Editing{})
	case is_browsing:
		browsing.index = next
		find_show(f, h.entries[next])
	case:
		// Browsing must be able to restore the draft, so without a copy of it nothing is recalled.
		copied, err := strings.clone(field_string(&f.query))
		if err != nil {return Find_Change.None}
		find_enter(f, Find_Browsing{next, {copied, f.options}})
		find_show(f, h.entries[next])
	}
	return Find_Change.Changed
}

@(private)
find_show :: proc(f: ^Find_Bar, entry: Find_Entry) {
	field_set(&f.query, entry.query)
	f.options = entry.options
}

@(private)
find_change :: proc(change: Field_Change) -> Find_Change {
	switch change {
	case .None:
		return Find_Change.None
	case .Moved:
		return Find_Change.Moved
	case .Edited:
	}
	return Find_Change.Changed
}

find_text :: proc(f: ^Find_Bar, text: string) -> Find_Outcome {
	outcome := find_change(field_text(&f.query, text))
	if outcome == Find_Change.Changed { find_edit(f) }
	return outcome
}

// Keep the overlay below the title chrome, where `caption_claim_height` says the caption
// controls claim pointer input, so they cannot intercept its events. The query, its toggles and the
// close button share the first row; the count and arrows follow them or wrap below on narrow windows.
find_layout :: proc(width, scale: f32, status_width: f32 = 0) -> Find_Layout {
	margin := FIND_MARGIN * scale
	panel_width := max(0, min(FIND_WIDTH * scale, width - 2 * margin))
	l: Find_Layout
	l.panel = {
		max(0, width - margin - panel_width),
		caption_claim_height(scale) + margin,
		panel_width,
		FIND_HEIGHT * scale,
	}
	padding, gap, button, toggle := FIND_PADDING * scale, 8 * scale, 32 * scale, FIND_TOGGLE * scale
	inner := max(0, panel_width - 2 * padding)
	row := render.Rect{l.panel.x + min(padding, panel_width), l.panel.y + 4 * scale, inner, button}
	controls := status_width + gap + 2 * button
	stacked := inner < 80 * scale + 2 * toggle + gap + controls + gap + button
	// The query and its toggles, and the two arrows, sit flush, so the gaps between groups are items of
	// their own. Tiny windows squeeze the controls; the stacks clip them so none reaches outside the panel.
	flush_end := Stack{align = .End}
	if !stacked {
		items := [?]Stack_Item {
			{fill = 1}, {size = toggle}, {size = toggle}, {size = gap}, {size = status_width},
			{size = gap}, {size = button}, {size = button}, {size = gap}, {size = button},
		}
		rects: [len(items)]render.Rect
		stack_layout(flush_end, row, items[:], rects[:])
		l.query, l.case_toggle, l.regex_toggle = rects[0], rects[1], rects[2]
		l.status, l.up, l.down, l.close = rects[4], rects[6], rects[7], rects[9]
		return l
	}
	query_items := [?]Stack_Item{{fill = 1}, {size = toggle}, {size = toggle}, {size = gap}, {size = button}}
	query_rects: [len(query_items)]render.Rect
	stack_layout(flush_end, row, query_items[:], query_rects[:])
	l.query, l.case_toggle, l.regex_toggle = query_rects[0], query_rects[1], query_rects[2]
	l.close = query_rects[4]
	row.y += FIND_HEIGHT * scale
	l.panel.height += FIND_HEIGHT * scale
	arrow_items := [?]Stack_Item{{size = status_width}, {size = gap}, {size = button}, {size = button}}
	arrow_rects: [len(arrow_items)]render.Rect
	// On very narrow windows give the count its own row to keep every digit visible.
	if inner < controls {
		stack_layout(Stack{}, row, arrow_items[:1], arrow_rects[:1])
		row.y += FIND_HEIGHT * scale
		l.panel.height += FIND_HEIGHT * scale
		stack_layout(flush_end, row, arrow_items[2:], arrow_rects[2:])
	} else {
		stack_layout(flush_end, row, arrow_items[:], arrow_rects[:])
	}
	l.status, l.up, l.down = arrow_rects[0], arrow_rects[2], arrow_rects[3]
	return l
}

find_contains :: proc(l: Find_Layout, x, y: f32) -> bool { return render.rect_contains(l.panel, x, y) }

// Toggles and close always respond; the arrows only when there are matches.
find_hit :: proc(l: Find_Layout, enabled: bool, x, y: f32) -> Find_Button {
	if render.rect_contains(l.close, x, y) { return .Close }
	if render.rect_contains(l.case_toggle, x, y) { return .Case_Toggle }
	if render.rect_contains(l.regex_toggle, x, y) { return .Regex_Toggle }
	if !enabled { return .None }
	if render.rect_contains(l.up, x, y) { return .Up }
	if render.rect_contains(l.down, x, y) { return .Down }
	return .None
}

// Text over the query, a hand over an enabled button.
find_pointer :: proc(l: Find_Layout, enabled: bool, x, y: f32) -> platform.Cursor_Shape {
	if find_hit(l, enabled, x, y) != .None {return .Hand}
	return render.rect_contains(l.query, x, y) ? .Text : .Arrow
}

find_hover :: proc(f: ^Find_Bar, l: Find_Layout, enabled: bool, x, y: f32) -> bool {
	hit := find_hit(l, enabled, x, y)
	if hit == f.hover { return false }
	f.hover = hit
	return true
}

// Moves each button's hover and press toward the pointer and the armed press; true when a frame is due.
find_animate :: proc(f: ^Find_Bar, animations: bool, frame: Frame_Time) -> bool {
	changed := false
	for &m, action in f.motion {
		hovered := f.hover == action && action != .None
		pressed := hovered && armed_is(f.armed, action)
		changed = control_update(&m, hovered, pressed, animations, frame) || changed
	}
	return changed
}

find_animating :: proc(f: ^Find_Bar) -> bool {
	for m in f.motion {if control_active(m) {return true}}
	return false
}

// Like other chrome buttons, activate only on a matching left press/release. A press anywhere on the bar
// gives it the keyboard.
find_mouse :: proc(f: ^Find_Bar, l: Find_Layout, enabled: bool, button: input.Mouse_Button,
	pressed: bool, x, y: f32) -> Find_Outcome {
	if button != .Left { return Find_Change.None }
	hit := find_hit(l, enabled, x, y)
	if pressed {
		find_focus(f)
		armed_press(&f.armed, hit)
		return Find_Change.Moved
	}
	fired, ok := armed_release(&f.armed, hit)
	if !ok { return Find_Change.Moved }
	return find_fire(f, fired)
}

// What pressing `button` does, by pointer or assistive technology; None presses nothing.
@(private = "file")
find_fire :: proc(f: ^Find_Bar, button: Find_Button) -> Find_Outcome {
	switch button {
	case .None:
	case .Up:
		return search.Step.Up
	case .Down:
		return search.Step.Down
	case .Close:
		return Find_Change.Closed
	case .Case_Toggle, .Regex_Toggle:
		return find_toggle(f, button)
	}
	return Find_Change.Moved
}

// The layout find_draw draws the bar and `status` in.
@(private = "file")
find_draw_layout :: proc(base: ^Text, status: string, width, scale: f32) -> Find_Layout {
	count := text_styled(base, .Detail)
	return find_layout(width, scale, text_width(&count, status))
}

// Draws the bar with `status` (such as "3 of 17") right-aligned after the query.
find_draw :: proc(
	f: ^Find_Bar,
	list: ^render.Draw_List,
	base: ^Text,
	theme: Theme,
	status: string,
	enabled: bool,
	width, height, scale: f32,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	input_text := text_styled(base, .Body)
	count := text_styled(base, .Detail)
	l := find_draw_layout(base, status, width, scale)
	panel := l.panel
	if panel.width <= 2 * FIND_PADDING * scale { return .Ok }
	if render.push_layer(list, {0, 0, width, height}) != .None {
		return .Ok
	}
	frame := popover_panel(panel, scale)
	if panel_draw(list, frame, theme) != .None {return .Ok}
	if result := draw_text(&count, list, status, l.status.x,
		l.status.y + (l.status.height - count.line_height) / 2 + count.ascent, theme.muted); result != .Ok {
		return result
	}
	buttons := [?]struct {
		area:   render.Rect,
		action: Find_Button,
		icon:   Icon,
		label:  string,
		on:     bool,
		live:   bool,
	} {
		{l.up, .Up, .Arrow_Up, "", false, enabled},
		{l.down, .Down, .Arrow_Down, "", false, enabled},
		{l.close, .Close, .Close, "", false, true},
		{l.case_toggle, .Case_Toggle, .None, "Aa", f.options.case_sensitive, true},
		{l.regex_toggle, .Regex_Toggle, .None, ".*", f.options.regex, true},
	}
	for b in buttons {
		if b.area.width <= 0 { continue }
		m := f.motion[b.action]
		face, ink, err := button_draw(
			list,
			theme,
			{rect = b.area, hover = m.hover.value, press = m.press.value, selected = b.on, disabled = !b.live},
			scale,
			pointer,
		)
		if err != .None { return .Ok }
		if len(b.label) == 0 {
			icon_draw(list, b.icon, face, ink, ICON_BUTTON, scale)
			continue
		}
		label := input_text
		x := face.x + (face.width - text_width(&label, b.label)) / 2
		baseline := face.y + (face.height - label.line_height) / 2 + label.ascent
		if result := draw_text(&label, list, b.label, x, baseline, ink); result != .Ok { return result }
	}
	if l.query.width <= 0 { return .Ok }
	box := Field_Box {
		field       = &f.query,
		text        = base,
		rect        = l.query,
		inset       = 0,
		radius      = 0,
		style       = .Body,
		scale       = scale,
	}
	return field_box_draw(box, list, theme, field_box_baseline(box), find_has_keyboard(f), FIND_HINT)
}

// The name assistive technology reads for each of the bar's buttons. The arrows take the names of the keys
// FIND_KEYS gives them, Shift+Enter and Enter, while they move up and down the screen as a click does.
@(rodata, private = "file")
FIND_ACCESS_NAMES := #partial [Find_Button]string {
	.Up           = "Previous match",
	.Down         = "Next match",
	.Close        = "Close",
	.Case_Toggle  = "Match case",
	.Regex_Toggle = "Regular expression",
}

// The query's hint, which also names it to assistive technology.
@(private = "file")
FIND_HINT :: "Find"

// The parts of the bar's access tree besides its buttons, whose parts are their Find_Button values.
@(private = "file")
FIND_ACCESS_GROUP :: max(u64)
@(private = "file")
FIND_ACCESS_STATUS :: max(u64) - 1

// Adds the open bar to the window's semantic tree under `parent`, as find_draw lays it out with the same
// `status`, `enabled`, `width` and `scale`: a Group named `name` holding the query, a Text_Field named
// "Find" as its hint says, then its toggles as Check_Boxes, `status` as a Status so a new count is read
// out, and the arrows and the close button as Buttons; the arrows are Disabled unless `enabled`.
//
// `id` is the query's; when the app registers the bar with Focus it passes platform.Access_Id of that
// Focus_Id, and gives the bar the keyboard with find_focus when assistive technology focuses `id`.
find_access :: proc(
	f: ^Find_Bar,
	t: ^Access_Tree,
	base: ^Text,
	parent, id: platform.Access_Id,
	name, status: string,
	enabled: bool,
	width, scale: f32,
) {
	if f.state == nil { return }
	l := find_draw_layout(base, status, width, scale)
	if l.panel.width <= 2 * FIND_PADDING * scale { return }
	group := access_part(id, FIND_ACCESS_GROUP)
	access_add(t, {id = group, parent = parent, role = .Group, name = name, bounds = access_bounds(l.panel)})
	if l.query.width > 0 {
		access_add(t, {id = id, parent = group, role = .Text_Field, name = FIND_HINT,
			value = field_string(&f.query), bounds = access_bounds(l.query), states = {.Focusable}})
	}
	toggles := [?]struct {
		area:   render.Rect,
		button: Find_Button,
		on:     bool,
	} {
		{l.case_toggle, .Case_Toggle, f.options.case_sensitive},
		{l.regex_toggle, .Regex_Toggle, f.options.regex},
	}
	for toggle in toggles {
		if toggle.area.width <= 0 { continue }
		states: bit_set[platform.Access_State;u16]
		if toggle.on { states += {.Checked} }
		access_add(t, {id = access_part(id, u64(toggle.button)), parent = group, role = .Check_Box,
			name = FIND_ACCESS_NAMES[toggle.button], bounds = access_bounds(toggle.area), states = states})
	}
	if status != "" && l.status.width > 0 {
		access_add(t, {id = access_part(id, FIND_ACCESS_STATUS), parent = group, role = .Status, name = status,
			bounds = access_bounds(l.status)})
	}
	buttons := [?]struct {
		area:   render.Rect,
		button: Find_Button,
		live:   bool,
	} {{l.up, .Up, enabled}, {l.down, .Down, enabled}, {l.close, .Close, true}}
	for b in buttons {
		if b.area.width <= 0 { continue }
		states: bit_set[platform.Access_State;u16]
		if !b.live { states += {.Disabled} }
		access_add(t, {id = access_part(id, u64(b.button)), parent = group, role = .Button,
			name = FIND_ACCESS_NAMES[b.button], bounds = access_bounds(b.area), states = states})
	}
}

// Does what assistive technology asked of a node find_access added under `id`, as clicking it does: Invoke
// on a button and Toggle on a toggle give the bar the keyboard and return the click's outcome. A disabled
// arrow, a closed bar and any other request do nothing.
find_access_invoke :: proc(
	f: ^Find_Bar,
	id: platform.Access_Id,
	e: platform.Access_Invoke_Event,
	enabled: bool,
) -> Find_Outcome {
	if f.state == nil { return Find_Change.None }
	for button in Find_Button {
		if button == .None || e.id != access_part(id, u64(button)) { continue }
		toggle := button == .Case_Toggle || button == .Regex_Toggle
		if e.action != (toggle ? platform.Access_Action.Toggle : .Invoke) { return Find_Change.None }
		if !enabled && (button == .Up || button == .Down) { return Find_Change.None }
		find_focus(f)
		return find_fire(f, button)
	}
	return Find_Change.None
}
