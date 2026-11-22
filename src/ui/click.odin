package ui

// The longest gap between the presses of a double click, for every control that tells one apart.
DOUBLE_CLICK_NS :: i64(500_000_000)

// How far the pointer may move between the presses of a double click, in pixels; a terminal's repeat
// click uses the same limit and interval.
DOUBLE_CLICK_DISTANCE :: f32(4)

// The presses of one run of clicks on a surface: where and when the last landed, how many the run has,
// and the offset the first one hit. A surface that redraws between the presses, as a Markdown editor
// does when the caret's line switches to its source, selects at `at` rather than at the pointer.
Click_Run :: struct {
	owner:   u32,
	x, y:    f32,
	time_ns: i64,
	count:   int,
	at:      int,
}

// The count a press at (`x`, `y`) on `owner` makes: one more than the run's while it lands within
// DOUBLE_CLICK_NS and DOUBLE_CLICK_DISTANCE of the run's last press, and one again after the third. A
// press must come after the last; events without a time never repeat.
@(require_results)
click_run_count :: proc(run: Click_Run, owner: u32, x, y: f32, time_ns: i64) -> int {
	dx, dy := x - run.x, y - run.y
	near := dx * dx + dy * dy <= DOUBLE_CLICK_DISTANCE * DOUBLE_CLICK_DISTANCE
	soon := time_ns > run.time_ns && time_ns - run.time_ns <= DOUBLE_CLICK_NS
	return run.count > 0 && run.owner == owner && near && soon ? run.count % 3 + 1 : 1
}

// Counts a press at `x` in the run of clicks `mark` holds, and records it. A press that extends the
// selection (Shift) never joins a run. The surface is one line tall, so only x tells presses apart.
@(require_results)
click_mark_press :: proc(mark: ^Click_Mark, x: f32, time_ns: i64, extend: bool) -> int {
	last := Click_Run {
		x       = mark.x,
		time_ns = mark.time_ns,
		count   = mark.count,
	}
	count := extend ? 1 : click_run_count(last, 0, x, 0, time_ns)
	mark^ = extend ? {} : {x, time_ns, count}
	return count
}

// A Left press in a text field at offset `at`, drawn at pointer column `x`: moves the caret there, or
// selects the word or the whole field on a double or triple click. Its drag goes through field_pointer.
field_press :: proc(f: ^Text_Field, at: int, x: f32, extend: bool, time_ns: i64) -> Field_Change {
	return field_pointer(f, at, true, extend, click_mark_press(&f.clicks, x, time_ns, extend))
}
