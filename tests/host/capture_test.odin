package host_test

import "cosmos:host"
import "core:testing"

@(private = "file")
Surface :: enum u8 {Content, Menu, Tabs}

@(private = "file")
Buttons :: host.Captures(Surface, Surface, u32)

// A press is held by the surface under it until its handler swallows, forwards or hands it on; only a held
// press changes hands, and a cancelled one reaches nothing until its release frees the button.
@(test)
captures_change_hands_only_while_held :: proc(t: ^testing.T) {
	c: Buttons
	host.capture_press(&c, .Left, Surface.Menu)
	host.capture_swallow(&c, .Left, Surface.Menu)
	host.capture_hand_off(&c, .Left, Surface.Tabs)
	swallowed, ok := c.buttons[.Left].(host.Capture_Swallowed(Surface))
	testing.expect(t, ok && swallowed.by == .Menu, "a swallowed press stays swallowed")

	host.capture_press(&c, .Right, Surface.Content)
	host.capture_forward(&c, .Right, 7)
	host.capture_press(&c, .Middle, Surface.Content)
	host.capture_hand_off(&c, .Middle, Surface.Tabs)
	held, _ := c.buttons[.Middle].(host.Capture_Held(Surface))
	testing.expect_value(t, held.owner, Surface.Tabs)
	testing.expect(t, host.capture_buttons(&c, host.Capture_Forwarded(u32)) == {.Right})
	testing.expect(t, host.capture_buttons(&c, host.Capture_Swallowed(Surface)) == {.Left})

	host.capture_cancel(&c, .Middle)
	host.capture_forward(&c, .Middle, 9)
	testing.expect(t, host.capture_buttons(&c, host.Capture_Cancelled) == {.Middle}, "cancelled stays cancelled")
	host.capture_cancel(&c, .Back)
	testing.expect(t, c.buttons[.Back] == nil, "a free button has nothing to cancel")

	released := host.capture_release(&c, .Right)
	forwarded, sent := released.(host.Capture_Forwarded(u32))
	testing.expect(t, sent && forwarded.to == 7)
	testing.expect(t, c.buttons[.Right] == nil, "the release frees the button")
}
