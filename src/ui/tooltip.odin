package ui

import "core:time"
import "core:unicode/utf8"

// How long the pointer rests on a control before its tooltip shows.
TOOLTIP_DELAY :: 700 * time.Millisecond
// How long after a visible tooltip was left a neighbour's shows at once.
TOOLTIP_GRACE :: time.Second
// A short pointer move between adjacent controls keeps tooltips warm across their gap, in DIPs.
TOOLTIP_NEIGHBOR_DISTANCE :: f32(80)
// The longest label kept, in bytes.
TOOLTIP_LIMIT :: 1024

// A window's tooltip: nil is Cold. Pending shows `label` at `deadline`; Visible shows it; Warm (after a
// visible tooltip was left) shows a neighbour's label at once until `until`. `anchor` is where the pointer
// last was over the label, for the neighbour distance.
Tooltip :: union {
	Tooltip_Pending,
	Tooltip_Visible,
	Tooltip_Warm,
}

Tooltip_Pending :: struct {
	label:    string,
	deadline: time.Tick,
	anchor:   [2]f32,
}

Tooltip_Visible :: struct {
	label:  string,
	anchor: [2]f32,
}

Tooltip_Warm :: struct {
	until:  time.Tick,
	anchor: [2]f32,
}

// A window's tooltip with the text its labels point into: a label may be built for one event in temporary
// memory, so the tooltip keeps a copy here. Only these procedures write either.
Tooltip_State :: struct {
	tooltip:      Tooltip,
	tooltip_text: [TOOLTIP_LIMIT]u8,
}

// `text` cut to at most `limit` bytes at a character boundary.
tooltip_clip :: proc(text: string, limit: int) -> string {
	if len(text) <= limit {return text}
	end := limit
	for end > 0 && !utf8.rune_start(text[end]) {end -= 1}
	return text[:end]
}

// The label the window is waiting to show or showing; empty when Cold or Warm.
tooltip_current :: proc(s: ^Tooltip_State) -> string {
	#partial switch t in s.tooltip {
	case Tooltip_Pending: return t.label
	case Tooltip_Visible: return t.label
	}
	return ""
}

tooltip_shown :: proc(s: ^Tooltip_State) -> (string, bool) {
	visible, ok := s.tooltip.(Tooltip_Visible)
	return visible.label, ok
}

tooltip_deadline :: proc(s: ^Tooltip_State) -> (time.Tick, bool) {
	pending, ok := s.tooltip.(Tooltip_Pending)
	return pending.deadline, ok
}

@(private = "file")
tooltip_store :: proc(s: ^Tooltip_State, label: string) -> string {
	return string(s.tooltip_text[:copy(s.tooltip_text[:], label)])
}

// The pointer moved to `point` over a control whose tooltip is `text`, empty for none; `buttons_down`
// cancels it. A new label waits TOOLTIP_DELAY, unless a tooltip showed within TOOLTIP_GRACE nearby. True
// when what shows may have changed, so the window redraws.
tooltip_hover :: proc(
	s: ^Tooltip_State,
	text: string,
	point: [2]f32,
	scale: f32,
	now: time.Tick,
	buttons_down: bool,
) -> bool {
	if buttons_down {return tooltip_cancel(s)}
	label := tooltip_clip(text, TOOLTIP_LIMIT)
	anchor: [2]f32
	switch t in s.tooltip {
	case Tooltip_Pending: anchor = t.anchor
	case Tooltip_Visible: anchor = t.anchor
	case Tooltip_Warm: anchor = t.anchor
	}
	dx, dy := point.x - anchor.x, point.y - anchor.y
	reach := TOOLTIP_NEIGHBOR_DISTANCE * max(1, scale)
	near := dx * dx + dy * dy <= reach * reach
	if label == tooltip_current(s) {
		switch &t in s.tooltip {
		case Tooltip_Pending: t.anchor = point
		case Tooltip_Visible: t.anchor = point
		case Tooltip_Warm: if !near {s.tooltip = nil}
		}
		return false
	}
	switch t in s.tooltip {
	case Tooltip_Visible:
		if label == "" {
			s.tooltip = Tooltip_Warm{time.tick_add(now, TOOLTIP_GRACE), anchor}
			return true
		}
		if near {
			s.tooltip = Tooltip_Visible{tooltip_store(s, label), point}
			return true
		}
	case Tooltip_Warm:
		if label != "" && near && time.tick_diff(now, t.until) > 0 {
			s.tooltip = Tooltip_Visible{tooltip_store(s, label), point}
			return true
		}
	case Tooltip_Pending:
	}
	if label == "" {
		s.tooltip = nil
		return true
	}
	s.tooltip = Tooltip_Pending{tooltip_store(s, label), time.tick_add(now, TOOLTIP_DELAY), point}
	return true
}

// Hides the tooltip and forgets its warmth. True when there was one, so the window redraws.
tooltip_cancel :: proc(s: ^Tooltip_State) -> bool {
	if s.tooltip == nil {return false}
	s.tooltip = nil
	return true
}

// Shows a pending tooltip once its deadline has passed. True when it did.
tooltip_tick :: proc(s: ^Tooltip_State, now: time.Tick) -> bool {
	pending, ok := s.tooltip.(Tooltip_Pending)
	if !ok || time.tick_diff(now, pending.deadline) > 0 {return false}
	s.tooltip = Tooltip_Visible{pending.label, pending.anchor}
	return true
}
