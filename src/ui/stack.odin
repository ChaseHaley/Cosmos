package ui

import "cosmos:render"

Stack_Axis :: enum {
	Row,
	Column,
}

Stack_Align :: enum {
	Start,
	Center,
	End,
}

// A row or column of items. `padding` insets the content from every side of the stack's rect and
// `spacing` separates neighbours; both are pixels. The same value lays the stack out and measures it.
Stack :: struct {
	axis:             Stack_Axis,
	spacing, padding: f32,
	// Places the run along the axis when no fill item has room to grow.
	align:            Stack_Align,
	// Places items that have a cross size across the content.
	cross_align:      Stack_Align,
}

// One item along the stack's axis. `size` is pixels, fixed or measured by the caller (a text width plus
// its inset). A positive `fill` weight grows the item from `size` by its share of the room left over.
// `cross` is the item's size across the axis, capped at the content's; zero stretches it across.
Stack_Item :: struct {
	size, fill, cross: f32,
}

// Writes the rect of each item into `out`, which is as long as `items`.
//
// Fill items share the room left over by weight. The items before the first fill are placed from the
// start and those after the last fill from the end, and the last fill ends exactly where the items after
// it begin, so neighbours meet without accumulated float error.
//
// When nothing fills, or the sizes and spacing leave no room for fills, every item keeps its size, fills
// included, and `align` places the run: Start overflows past the end, End past the start and Center past
// both. Every rect is then clipped to the content along the axis, so an item that overflows shrinks to
// the part inside, down to an empty rect on the edge.
//
// Positions and sizes are not rounded: callers pass pixels already multiplied by the window scale, and
// fractional inputs or fill shares give fractional rects.
stack_layout :: proc(s: Stack, r: render.Rect, items: []Stack_Item, out: []render.Rect) {
	assert(len(out) == len(items), "stack_layout needs one output rect per item")
	inset_x, inset_y := min(s.padding, r.width / 2), min(s.padding, r.height / 2)
	content := render.Rect{r.x + inset_x, r.y + inset_y, r.width - 2 * inset_x, r.height - 2 * inset_y}
	row := s.axis == .Row
	start, room := row ? content.x : content.y, row ? content.width : content.height
	cross_start, cross_room := row ? content.y : content.x, row ? content.height : content.width

	// The first passes keep each item's position along the axis in x and its length in width.
	first, last := -1, -1
	weight: f32
	for item, i in items {
		if item.fill <= 0 {continue}
		if first < 0 {first = i}
		last = i
		weight += item.fill
	}
	filled := false
	if first >= 0 {
		a := stack_forward(s, items[:first], out[:first], start)
		b := stack_backward(s, items[last + 1:], out[last + 1:], start + room)
		middle := items[first:last + 1]
		free := b - a - stack_run(s, middle)
		if free > 0 {
			cursor := a
			for item, i in middle {
				size := item.size + free * max(item.fill, 0) / weight
				if i == len(middle) - 1 {size = b - cursor}
				out[first + i].x, out[first + i].width = cursor, size
				cursor = cursor + size + s.spacing
			}
			filled = true
		}
	}
	if !filled {
		switch s.align {
		case .Start:
			stack_forward(s, items, out, start)
		case .Center:
			stack_forward(s, items, out, start + (room - stack_run(s, items)) / 2)
		case .End:
			stack_backward(s, items, out, start + room)
		}
	}

	for &rect, i in out {
		near := clamp(rect.x, start, start + room)
		far := clamp(rect.x + rect.width, start, start + room)
		length := max(0, far - near)
		across, offset := cross_room, f32(0)
		if items[i].cross > 0 {
			across = min(items[i].cross, cross_room)
			switch s.cross_align {
			case .Start:
			case .Center:
				offset = (cross_room - across) / 2
			case .End:
				offset = cross_room - across
			}
		}
		if row {
			rect = {near, cross_start + offset, length, across}
		} else {
			rect = {cross_start + offset, near, across, length}
		}
	}
}

// The length along the axis the stack needs to give every item its size: the sizes, the spacing between
// them and the padding at both ends. A parent stack takes it as the size or cross size of an item.
stack_measure :: proc(s: Stack, items: []Stack_Item) -> f32 {
	return stack_run(s, items) + 2 * s.padding
}

@(private = "file")
stack_run :: proc(s: Stack, items: []Stack_Item) -> f32 {
	run: f32
	for item, i in items {
		run += item.size
		if i > 0 {run += s.spacing}
	}
	return run
}

// Places items one after another from `cursor` and returns where a following item would start.
@(private = "file")
stack_forward :: proc(s: Stack, items: []Stack_Item, out: []render.Rect, cursor: f32) -> f32 {
	cursor := cursor
	for item, i in items {
		out[i].x, out[i].width = cursor, item.size
		cursor = cursor + item.size + s.spacing
	}
	return cursor
}

// Places items one before another back from `cursor` and returns where a preceding item would end.
@(private = "file")
stack_backward :: proc(s: Stack, items: []Stack_Item, out: []render.Rect, cursor: f32) -> f32 {
	cursor := cursor
	#reverse for item, i in items {
		cursor -= item.size
		out[i].x, out[i].width = cursor, item.size
		cursor -= s.spacing
	}
	return cursor
}
