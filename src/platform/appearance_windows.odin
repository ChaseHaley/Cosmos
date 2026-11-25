package platform

@(require) import "cosmos:input"
@(require) import "core:log"
@(require) import w "core:sys/windows"

// The Win32 backend; a headless build compiles another (see HEADLESS in platform.odin).
when !HEADLESS {
	// The appearance as of init or the last change the host window heard of.
	system_appearance :: proc(p: ^Platform) -> Appearance {
		return p.appearance
	}

	@(require_results)
	window_set_dark :: proc(p: ^Platform, id: input.Window_Id, dark: bool) -> Error {
		window := find_window(p, id)
		if window == nil {return .Invalid_Window}
		if hr := frame_dark_set(window.hwnd, dark); hr < 0 {
			log.errorf("DwmSetWindowAttribute(dark) failed: HRESULT %x", u32(hr))
			return .Os
		}
		// DWM repaints a shown caption in its new mode only once the frame is recalculated.
		flags := u32(w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOACTIVATE | w.SWP_FRAMECHANGED)
		if !os_ok(w.SetWindowPos(window.hwnd, nil, 0, 0, 0, 0, flags), "SetWindowPos(dark)") {return .Os}
		return .None
	}

	@(private)
	frame_dark_set :: proc(hwnd: w.HWND, dark: bool) -> w.HRESULT {
		value := w.BOOL(dark)
		return w.DwmSetWindowAttribute(
			hwnd,
			u32(w.DWMWINDOWATTRIBUTE.DWMWA_USE_IMMERSIVE_DARK_MODE),
			&value,
			size_of(value),
		)
	}

	// Whether a WM_SETTINGCHANGE can concern the appearance: Windows names a light or dark or accent
	// change "ImmersiveColorSet", and a high contrast change by its SPI.
	@(private)
	appearance_setting :: proc(wp: w.WPARAM, lp: w.LPARAM) -> bool {
		if wp == w.SPI_SETHIGHCONTRAST {return true}
		if lp == 0 {return false}
		name := ([^]u16)(rawptr(uintptr(lp)))
		expected :: "ImmersiveColorSet"
		for c, i in expected {
			if name[i] != u16(c) {return false}
		}
		return name[len(expected)] == 0
	}

	// Reads the appearance again and reports it only when it differs from the last one read.
	@(private)
	appearance_refresh :: proc(p: ^Platform) {
		next := appearance_read()
		if next == p.appearance {return}
		p.appearance = next
		enqueue(p, Appearance_Event{next})
	}

	// A setting that cannot be read keeps its default: light apps, no high contrast, no accent.
	@(private)
	appearance_read :: proc() -> Appearance {
		appearance: Appearance
		personalize: cstring16 = w.L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize")
		// Windows writes no AppsUseLightTheme until the user first picks a mode, and apps are then light.
		if light, found := registry_dword(personalize, w.L("AppsUseLightTheme")); found {
			appearance.dark = light == 0
		}
		// AccentColor holds 0xAABBGGRR.
		dwm: cstring16 = w.L("Software\\Microsoft\\Windows\\DWM")
		if accent, found := registry_dword(dwm, w.L("AccentColor")); found {
			appearance.accent = [3]u8{u8(accent), u8(accent >> 8), u8(accent >> 16)}
		}
		contrast := HIGHCONTRASTW {
			cbSize = size_of(HIGHCONTRASTW),
		}
		if w.SystemParametersInfoW(w.SPI_GETHIGHCONTRAST, size_of(contrast), &contrast, 0) {
			appearance.high_contrast = contrast.dwFlags & HCF_HIGHCONTRASTON != 0
		} else {
			log.errorf("SystemParametersInfoW(SPI_GETHIGHCONTRAST) failed: %d", w.GetLastError())
		}
		return appearance
	}

	// A DWORD under HKEY_CURRENT_USER; a missing key or value is not found, without a log.
	@(private)
	registry_dword :: proc(key, value: cstring16) -> (u32, bool) {
		data: w.DWORD
		size := w.DWORD(size_of(data))
		status := w.RegGetValueW(w.HKEY_CURRENT_USER, key, value, w.RRF_RT_REG_DWORD, nil, &data, &size)
		if status == 0 {return data, true}
		if w.DWORD(status) != w.ERROR_FILE_NOT_FOUND {
			log.errorf("RegGetValueW(%v) failed: %d", value, status)
		}
		return 0, false
	}
}
