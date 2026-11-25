package platform_test

import p "cosmos:platform"
import "core:testing"
import w "core:sys/windows"

// Hidden windows open with a light or a dark frame, whether or not this Windows can draw the dark one,
// and the frame can change after.
@(test)
windows_open_with_either_frame :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.Frames"), p.Init_Result.Primary) {return}
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	light, light_error := p.window_create(&platform, {hidden = true, width = 160, height = 100})
	testing.expect_value(t, light_error, p.Error.None)
	dark, dark_error := p.window_create(&platform, {hidden = true, width = 160, height = 100, dark = true})
	testing.expect_value(t, dark_error, p.Error.None)
	testing.expect_value(t, p.window_set_dark(&platform, light, true), p.Error.None)
	testing.expect_value(t, p.window_set_dark(&platform, dark, false), p.Error.None)
	testing.expect_value(t, p.window_set_dark(&platform, 9999, true), p.Error.Invalid_Window)
}

// The appearance reads apps' light or dark mode and the accent colour as Windows stores them: dark when
// AppsUseLightTheme is 0 and light when it is missing, and the accent's red in AccentColor's low byte.
@(test)
appearance_reads_the_users_settings :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.Appearance"), p.Init_Result.Primary) {return}
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	appearance := p.system_appearance(&platform)
	read :: proc(key, value: cstring16) -> (u32, bool) {
		data: w.DWORD
		size := w.DWORD(size_of(data))
		status := w.RegGetValueW(w.HKEY_CURRENT_USER, key, value, w.RRF_RT_REG_DWORD, nil, &data, &size)
		return data, status == 0
	}
	personalize: cstring16 = w.L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize")
	light, has_light := read(personalize, w.L("AppsUseLightTheme"))
	testing.expect_value(t, appearance.dark, has_light && light == 0)
	accent, has_accent := read(w.L("Software\\Microsoft\\Windows\\DWM"), w.L("AccentColor"))
	if has_accent {
		rgb := [3]u8{u8(accent), u8(accent >> 8), u8(accent >> 16)}
		testing.expect_value(t, appearance.accent, Maybe([3]u8)(rgb))
	} else {
		testing.expect_value(t, appearance.accent, nil)
	}
}
