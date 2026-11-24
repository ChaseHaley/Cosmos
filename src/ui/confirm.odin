package ui

import "cosmos:input"
import "cosmos:render"

Confirm_Button :: enum {
	None,
	Option,
	Cancel,
	Accept,
}

Confirm_Outcome :: enum {
	None,
	Changed,
	Cancel,
	Accept,
}

// A modal question with Cancel and Accept buttons. Accept has the keyboard first so Enter confirms,
// unless the question opens with Cancel focused. While it asks, the dialog is a scope of the window's
// Focus: Tab and the arrows walk its own controls, and closing it gives focus back.
Confirm :: struct {
	using presence: Presence,
	hover:          Confirm_Button,
	armed:          Armed(Confirm_Button),
	hover_motion:   Control_Motion,
	// The option's focus id; Cancel and Accept take the two after it.
	id:             Focus_Id,
	scope:          Focus_Scope,
	extended:       bool,
	show_option:    bool,
	option:         bool,
}

Confirm_Layout :: struct {
	panel, option, cancel, accept: render.Rect,
}

@(private)
CONFIRM_WIDTH :: 380
@(private)
CONFIRM_HEIGHT :: 144
@(private)
CONFIRM_BUTTON_WIDTH :: 96
@(private)
CONFIRM_BUTTON_HEIGHT :: HEIGHT_STANDARD

// Opens the dialog as a fresh question, so one asked again while it fades fades in from nothing. The
// caller states the whole presentation here: the wide panel, the button that has the keyboard first and
// whether the option shows. The option always starts unchecked. The dialog's controls take the focus ids
// `id` (the option), `id + 1` (Cancel) and `id + 2` (Accept). Its first focus shows the ring, since Enter
// answers with whichever button has it.
confirm_open :: proc(
	c: ^Confirm,
	f: ^Focus,
	id: Focus_Id,
	extended := false,
	focus := Confirm_Button.Accept,
	show_option := false,
) {
	assert(id != 0 && focus != .None && (focus != .Option || show_option))
	// A question asked again while it asks keeps its scope, so focus still returns where it was before.
	scope := c.scope
	if !presence_is_open(c.presence) {scope = focus_scope_open(f)}
	c^ = {id = id, scope = scope, extended = extended, show_option = show_option}
	focus_set(f, confirm_focus_id(c^, focus), true)
	presence_open(&c.presence, DIALOG_PRESENCE)
}

confirm_close :: proc(c: ^Confirm, f: ^Focus) {
	if presence_is_open(c.presence) {focus_scope_close(f, c.scope)}
	presence_close(&c.presence)
	c.hover = .None
	armed_cancel(&c.armed)
}

// Registers the dialog's controls in its scope while it asks; the owner calls this in every frame it
// builds between focus_frame_begin and focus_frame_end.
confirm_focus_add :: proc(c: ^Confirm, f: ^Focus) {
	if !presence_is_open(c.presence) {return}
	if c.show_option {focus_add(f, confirm_focus_id(c^, .Option), c.scope)}
	focus_add(f, confirm_focus_id(c^, .Cancel), c.scope)
	focus_add(f, confirm_focus_id(c^, .Accept), c.scope)
}

// The dialog's control that has the keyboard, or None when focus is elsewhere.
confirm_focused :: proc(c: Confirm, f: Focus) -> Confirm_Button {
	for button in Confirm_Button {
		if button != .None && f.focused == confirm_focus_id(c, button) {return button}
	}
	return .None
}

@(private)
confirm_focus_id :: proc(c: Confirm, button: Confirm_Button) -> Focus_Id {
	return c.id + Focus_Id(int(button) - int(Confirm_Button.Option))
}

confirm_layout :: proc(width, height, scale: f32, extended := false, show_option := false) -> Confirm_Layout {
	s := scale
	panel_width := min((extended ? 540 : CONFIRM_WIDTH) * s, max(0, width - 32 * s))
	panel := render.Rect {
		(width - panel_width) / 2,
		max(24 * s, height * 0.22),
		panel_width,
		CONFIRM_HEIGHT * s,
	}
	pad := DIALOG_PADDING * s
	y := panel.y + panel.height - pad - CONFIRM_BUTTON_HEIGHT * s
	accept := render.Rect {
		panel.x + panel.width - pad - CONFIRM_BUTTON_WIDTH * s,
		y,
		CONFIRM_BUTTON_WIDTH * s,
		CONFIRM_BUTTON_HEIGHT * s,
	}
	cancel := accept
	cancel.x -= CONFIRM_BUTTON_WIDTH * s + 8 * s
	option := render.Rect{}
	if show_option {
		option = {
			panel.x + pad,
			y,
			max(0, cancel.x - 8 * s - panel.x - pad),
			CONFIRM_BUTTON_HEIGHT * s,
		}
	}
	return {panel, option, cancel, accept}
}

confirm_hit :: proc(l: Confirm_Layout, x, y: f32) -> Confirm_Button {
	if l.option.width > 0 && render.rect_contains(l.option, x, y) {return .Option}
	if render.rect_contains(l.accept, x, y) {return .Accept}
	if render.rect_contains(l.cancel, x, y) {return .Cancel}
	return .None
}

confirm_contains :: proc(l: Confirm_Layout, x, y: f32) -> bool {return render.rect_contains(l.panel, x, y)}

// The option's accelerator is Alt with the first letter of its label, so "Don't ask again" is Alt+D.
@(private)
confirm_option_key :: proc(label: string) -> (input.Key, bool) {
	for r in label {
		switch r {
		case 'a' ..= 'z': return input.Key(int(input.Key.A) + int(r - 'a')), true
		case 'A' ..= 'Z': return input.Key(int(input.Key.A) + int(r - 'A')), true
		}
		break
	}
	return .Unidentified, false
}

// `option_label` is the option's text as drawn; it names the option's accelerator. Tab and the arrows move
// through the controls the dialog registered with confirm_focus_add.
confirm_key :: proc(c: ^Confirm, f: ^Focus, e: input.Key_Event, option_label: string) -> Confirm_Outcome {
	if !e.pressed {return .None}
	if key, ok := confirm_option_key(option_label);
	   ok && c.show_option && .Alt in e.modifiers && e.key == key {
		c.option = !c.option
		focus_set(f, confirm_focus_id(c^, .Option), true)
		return .Changed
	}
	focused := confirm_focused(c^, f^)
	#partial switch e.key {
	case .Escape:
		return .Cancel
	case .Enter, .Numpad_Enter:
		return focused == .Cancel ? .Cancel : .Accept
	case .Space:
		if focused == .Option {
			c.option = !c.option
			return .Changed
		}
		return focused == .Cancel ? .Cancel : .Accept
	case .Tab:
		return focus_key(f, e) ? .Changed : .None
	case .Arrow_Left, .Arrow_Up:
		return focus_move(f, true) ? .Changed : .None
	case .Arrow_Right, .Arrow_Down:
		return focus_move(f, false) ? .Changed : .None
	}
	return .None
}

// Pointer presses arm a button; the release activates it only over the same button. A press focuses
// what it lands on without the ring, as pointer focus does everywhere.
confirm_mouse :: proc(
	c: ^Confirm,
	f: ^Focus,
	l: Confirm_Layout,
	button: input.Mouse_Button,
	pressed: bool,
	x, y: f32,
) -> Confirm_Outcome {
	if button != .Left {return .None}
	hit := confirm_hit(l, x, y)
	if pressed {
		if hit == .Option {
			c.option = !c.option
			focus_set(f, confirm_focus_id(c^, .Option), false)
			return .Changed
		}
		if hit == .None && !confirm_contains(l, x, y) {return .Cancel}
		armed_press(&c.armed, hit)
		if hit != .None {focus_set(f, confirm_focus_id(c^, hit), false)}
		return .Changed
	}
	fired, ok := armed_release(&c.armed, hit)
	if ok && fired != .None {return fired == .Accept ? .Accept : .Cancel}
	return .Changed
}

confirm_hover :: proc(c: ^Confirm, l: Confirm_Layout, x, y: f32) -> bool {
	hit := confirm_hit(l, x, y)
	if hit == c.hover {return false}
	c.hover = hit
	return true
}

@(private)
confirm_button_draw :: proc(
	c: ^Confirm,
	f: Focus,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	rect: render.Rect,
	button: Confirm_Button,
	label: string,
	scale: f32,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	accept := button == .Accept
	active := armed_is(c.armed, button)
	hover := c.hover == button ? c.hover_motion.hover.value : 0
	lift := hover_lift_at(theme, hover, scale)
	r := rect
	r.y -= lift
	if lift > 0 {
		if result := hover_shadow_draw(list, theme, r, RADIUS_CONTROL * scale, hover, scale);
		   result != .None {return .Ok}
	}
	fill := accept ? theme.error : theme.border
	if !accept && active {fill = theme.pressed} else if !accept && hover > 0 {
		fill = theme.hover
		fill.a *= hover
	}
	draw_rect(list, {rect = r, color = fill, radius = RADIUS_CONTROL * scale})
	if accept && active {
		draw_rect(list, {rect = r, color = theme.pressed, radius = RADIUS_CONTROL * scale})
	}
	if focus_visible(f, confirm_focus_id(c^, button)) {focus_ring_draw(list, r, theme, scale)}
	strong := text_styled(text, .Strong)
	color := accept ? theme.accent_text : theme.text
	if result := draw_text(
		&strong,
		list,
		label,
		r.x + (r.width - text_width(&strong, label)) / 2,
		r.y + (r.height - strong.line_height) / 2 + strong.ascent,
		color,
		r.width - 8 * scale,
	); result != .Ok {return result}
	if hover > 0 {
		// The destructive button keeps its error fill, so it takes no paper hairline.
		if result := hover_rim_draw(list, theme, r, RADIUS_CONTROL * scale, hover, scale, pointer, !accept);
		   result != .None {return .Ok}
	}
	return .Ok
}

confirm_draw :: proc(
	c: ^Confirm,
	f: Focus,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	width, height, scale: f32,
	title, body, accept_label: string,
	note: string,
	option_label: string = "",
	fade := FADE_NONE,
	pointer: [2]f32 = {},
	cancel_label := "Cancel",
) -> render.Build_Status {
	l := confirm_layout(width, height, scale, c.extended, c.show_option)
	s := scale
	mark := render.draw_mark(list)
	defer fade_draw(list, mark, fade)
	if render.push_layer(list, {0, 0, width, height}) != .None {return .Ok}
	draw_rect(list, {rect = {0, 0, width, height}, color = theme.scrim})
	p := l.panel
	frame := dialog_panel(p, s)
	if panel_draw(list, frame, theme) != .None {return .Ok}
	heading := text_styled(text, .Title)
	pad := DIALOG_PADDING * s
	inner := p.width - 2 * pad
	top := p.y + pad
	if r := draw_fading_text(
		&heading,
		list,
		title,
		p.x + pad,
		top + heading.ascent,
		theme.text,
		inner,
	); r != .Ok {
		return r
	}
	top += heading.line_height + 8 * s
	small := text_styled(text, .Detail)
	if r := draw_text(
		text,
		list,
		body,
		p.x + pad,
		top + text.ascent,
		theme.muted,
		inner,
	); r != .Ok {
		return r
	}
	top += text.line_height + SPACE_1 * s
	if r := draw_fading_text(
		&small,
		list,
		note,
		p.x + pad,
		top + small.ascent,
		theme.faint,
		inner,
	); r != .Ok {return r}
	if c.show_option && option_label != "" {
		box := checkbox_rect(l.option.x, l.option.y, l.option.height, s)
		checkbox_draw(list, box, c.option, theme, s)
		if focus_visible(f, confirm_focus_id(c^, .Option)) {focus_ring_draw(list, box, theme, s)}
		if r := draw_text(
			&small,
			list,
			option_label,
			box.x + box.width + 8 * s,
			box.y + (box.height - small.line_height) / 2 + small.ascent,
			theme.muted,
			max(0, l.option.width - box.width - 8 * s),
		); r != .Ok {return r}
	}
	if r := confirm_button_draw(c, f, list, text, theme, l.cancel, .Cancel, cancel_label, s, pointer);
	   r != .Ok {return r}
	return confirm_button_draw(c, f, list, text, theme, l.accept, .Accept, accept_label, s, pointer)
}
