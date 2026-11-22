package ui

import "cosmos:colour"
import "cosmos:render"
import "cosmos:theme"

// The designed raised hover: how far a hovered control rises, in DIPs, and the strength of its
// pointer-following rim light. An app may let the user scale either.
HOVER_LIFT_DEFAULT :: f32(1.5)
HOVER_GLOSS_DEFAULT :: f32(1)

// The widget colours of a resolved family theme. `hover_lift` and `hover_gloss` scale the raised hover
// and its sheen, from 0 for none.
theme_from :: proc(t: theme.Theme, hover_lift, hover_gloss: f32) -> Theme {
	c :: proc(t: theme.Theme, token: theme.Token) -> render.Color {
		value := t.colors[token]
		return colour.rgba(value.rgb, f32(value.a) / 255)
	}
	text, raised, accent := t.colors[.Text].rgb, t.colors[.Surface].rgb, t.colors[.Accent].rgb
	return {
		window = c(t, .Window),
		pane = c(t, .Pane),
		surface = c(t, .Surface),
		text = c(t, .Text),
		muted = c(t, .Muted),
		faint = c(t, .Faint),
		accent = c(t, .Accent),
		accent_text = c(t, .Accent_Text),
		border = c(t, .Border),
		selection = c(t, .Selection),
		focus = c(t, .Focus),
		caret = colour.rgba(theme.cursor(t)),
		caret_text = colour.rgba(theme.cursor_text(t)),
		text_selection = c(t, .Selection_Background),
		text_selection_text = t.colors[.Selection_Foreground].a != 0 ? c(t, .Selection_Foreground) : nil,
		error = c(t, .Danger),
		success = c(t, .Success),
		warning = c(t, .Warning),
		info = c(t, .Info),
		tab_bar = c(t, .Tab_Bar),
		tab_text = c(t, .Tab_Text),
		tab_active = c(t, .Tab_Active),
		tab_active_text = c(t, .Tab_Active_Text),
		tab_indicator = c(t, .Tab_Indicator),
		rail_active = c(t, .Rail_Active),
		pane_border = c(t, .Pane_Border),
		pane_focus = c(t, .Pane_Focus),
		scrollbar_track = c(t, .Scrollbar_Track),
		scrollbar = c(t, .Scrollbar),
		scrollbar_hover = c(t, .Scrollbar_Hover),
		scrollbar_active = c(t, .Scrollbar_Active),
		// Light mode's hover is paper: the opaque raised-surface colour, so the seat drawn underneath
		// cannot show through and darken the tile, and its shape comes from the hairline and the seat
		// rather than from ink. Dark mode keeps the translucent lift.
		hover = t.light ? colour.rgba(raised) : colour.rgba(text, 0.05),
		pressed = colour.rgba(text, t.light ? 0.08 : 0.09),
		shadow = {0, 0, 0, t.light ? 0.12 : 0.35},
		scrim = {0, 0, 0, t.light ? 0.08 : 0.18},
		// White light reads as a specular edge on dark surfaces. On a white control the rim must stay
		// faint, or it becomes the dark edge the paper fill exists to avoid.
		rim = colour.rgba(t.light ? accent : text, t.light ? 0.20 : 0.80),
		hover_edge = t.light ? colour.rgba(text, 0.10) : render.Color{0, 0, 0, 0},
		hover_lift = hover_lift,
		hover_gloss = hover_gloss,
	}
}
