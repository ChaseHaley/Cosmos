package host_test

import "cosmos:host"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
count_wakes :: proc "contextless" (data: rawptr) {
	sync.atomic_add((^int)(data), 1)
}

@(test)
an_inbox_hands_over_every_item_in_order_and_wakes_once_per_push :: proc(t: ^testing.T) {
	wakes := 0
	inbox: host.Inbox(int)
	host.inbox_init(&inbox, {count_wakes, &wakes})
	defer host.inbox_destroy(&inbox)
	Worker :: struct {
		inbox: ^host.Inbox(int),
		start: int,
	}
	push :: proc(w: ^Worker) {
		for i in 0 ..< 100 {_ = host.inbox_push(w.inbox, w.start + i)}
	}
	a, b := Worker{&inbox, 0}, Worker{&inbox, 1000}
	ta := thread.create_and_start_with_poly_data(&a, push)
	tb := thread.create_and_start_with_poly_data(&b, push)
	thread.join_multiple(ta, tb)
	thread.destroy(ta)
	thread.destroy(tb)
	testing.expect(t, host.inbox_pending(&inbox))
	taken: [dynamic]int
	defer delete(taken)
	testing.expect_value(t, host.inbox_take(&inbox, &taken), nil)
	testing.expect_value(t, len(taken), 200)
	testing.expect_value(t, sync.atomic_load(&wakes), 200)
	testing.expect(t, !host.inbox_pending(&inbox))
	// Each worker's items keep their order.
	last := [2]int{-1, 999}
	for item in taken {
		worker := item < 1000 ? 0 : 1
		testing.expect(t, item > last[worker])
		last[worker] = item
	}
}

@(test)
an_inbox_releases_what_nobody_took :: proc(t: ^testing.T) {
	inbox: host.Inbox(^int)
	host.inbox_init(&inbox, {})
	value := new(int)
	testing.expect_value(t, host.inbox_push(&inbox, value), nil)
	host.inbox_destroy(&inbox, proc(item: ^^int) {free(item^)})
}

@(test)
a_signal_coalesces_raises_until_taken :: proc(t: ^testing.T) {
	wakes := 0
	signal := host.Signal {
		waker = {count_wakes, &wakes},
	}
	testing.expect(t, !host.signal_take(&signal))
	host.signal_raise(&signal)
	host.signal_raise(&signal)
	testing.expect(t, host.signal_raised(&signal))
	testing.expect(t, host.signal_take(&signal))
	testing.expect(t, !host.signal_take(&signal))
	testing.expect_value(t, wakes, 2)
	waker := host.signal_waker(&signal)
	host.wake(waker)
	testing.expect(t, host.signal_take(&signal))
	host.wake({})
}

@(test)
a_blink_flips_on_its_deadline_and_typing_shows_the_caret :: proc(t: ^testing.T) {
	start := time.tick_now()
	interval := 500 * time.Millisecond
	blink: host.Blink
	testing.expect(t, host.blink_visible(blink))
	_, blinking := host.blink_deadline(blink)
	testing.expect(t, !blinking)
	host.blink_observe(&blink, true, interval, start)
	deadline, running := host.blink_deadline(blink)
	testing.expect(t, running)
	testing.expect_value(t, deadline, time.tick_add(start, interval))
	testing.expect(t, !host.blink_tick(&blink, time.tick_add(start, interval / 2)))
	testing.expect(t, host.blink_tick(&blink, deadline))
	testing.expect(t, !host.blink_visible(blink))
	host.blink_reset(&blink, deadline)
	testing.expect(t, host.blink_visible(blink))
	// A running cycle keeps its phase when the interval changes.
	host.blink_observe(&blink, true, interval * 2, deadline)
	next, _ := host.blink_deadline(blink)
	testing.expect_value(t, next, time.tick_add(deadline, interval))
	host.blink_observe(&blink, false, interval, deadline)
	testing.expect(t, blink == nil)
}

@(test)
deadlines_fold_to_the_earliest_and_round_the_wait_up :: proc(t: ^testing.T) {
	now := time.tick_now()
	later, soon := time.tick_add(now, time.Second), time.tick_add(now, 10 * time.Millisecond)
	deadline, found := host.earliest({}, false, later)
	deadline, found = host.earliest(deadline, found, soon)
	deadline, found = host.earliest(deadline, found, later)
	testing.expect(t, found)
	testing.expect_value(t, deadline, soon)
	testing.expect_value(t, host.wait_ms(deadline, found, now), 11)
	testing.expect_value(t, host.wait_ms(now, true, soon), 0)
	testing.expect_value(t, host.wait_ms({}, false, now), max(u32))
	testing.expect_value(t, host.wait_ms(time.tick_add(now, time.Hour), true, now), host.WAIT_LIMIT_MS)
}

// A quit or restart held for a reply keeps the loop running until released; a lost device ends it at once
// and is never held; only a running loop starts a quit or restart.
@(test)
a_held_quit_runs_until_released :: proc(t: ^testing.T) {
	run: host.Run
	host.quit(&run)
	testing.expect(t, host.quit_hold(&run))
	testing.expect_value(t, run, host.Run.Draining)
	testing.expect(t, host.running(run), "a held quit keeps the loop going")
	host.restart(&run)
	testing.expect(t, run == .Draining, "a held quit stays a quit")
	host.quit_release(&run)
	testing.expect_value(t, run, host.Run.Quit)
	testing.expect(t, !host.running(run))

	run = .Restart
	testing.expect(t, host.quit_hold(&run))
	host.quit_release(&run)
	testing.expect_value(t, run, host.Run.Restart)

	host.device_failed(&run)
	testing.expect(t, !host.quit_hold(&run), "a failed device is not held")
	host.quit(&run)
	testing.expect_value(t, run, host.Run.Device_Failed)
}
