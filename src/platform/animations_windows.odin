package platform

@(require) import "core:log"
@(require) import win "core:sys/windows"

// The Win32 backend; a headless build compiles another (see HEADLESS in platform.odin).
when !HEADLESS {
	client_animations_enabled :: proc() -> bool {
		enabled: win.BOOL
		if !win.SystemParametersInfoW(win.SPI_GETCLIENTAREAANIMATION, 0, &enabled, 0) {
			log.errorf("SystemParametersInfoW client area animations failed: %v", win.GetLastError())
			return false
		}
		return enabled != false
	}
}
