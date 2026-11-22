package host

import "cosmos:platform"

// Whether the main loop goes round again, and why it stopped. The procedures below are its only writers.
Run :: enum u8 {
	Running,
	// A quit waits while a control channel delivers its reply to the request that caused it.
	Draining,
	// A restart waits the same way, then goes on as a Restart.
	Draining_Restart,
	// The owner quit.
	Quit,
	// The owner quits to start the app again, as after an update; main starts it once this one has let go.
	Restart,
	// The graphics device was lost and could not be recreated.
	Device_Failed,
}

running :: proc(r: Run) -> bool {
	return r == .Running || r == .Draining || r == .Draining_Restart
}

// A quit already being drained stays drained, so its reply still arrives.
quit :: proc(r: ^Run) {
	if r^ == .Running {r^ = .Quit}
}

// Whoever asks, the restarted app takes the foreground only when this one holds it now.
restart :: proc(r: ^Run) {
	if r^ != .Running {return}
	platform.foreground_pass_on()
	r^ = .Restart
}

// Nothing can draw without a device, so no reply is worth waiting for.
device_failed :: proc(r: ^Run) {
	r^ = .Device_Failed
}

// Holds the owner's quit or restart open until quit_release; a failed device is not held.
@(require_results)
quit_hold :: proc(r: ^Run) -> bool {
	#partial switch r^ {
	case .Quit:
		r^ = .Draining
	case .Restart:
		r^ = .Draining_Restart
	case:
		return false
	}
	return true
}

quit_release :: proc(r: ^Run) {
	#partial switch r^ {
	case .Draining:
		r^ = .Quit
	case .Draining_Restart:
		r^ = .Restart
	}
}
