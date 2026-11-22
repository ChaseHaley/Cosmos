package winpath_test

import "core:testing"
import "cosmos:winpath"

@(test)
path_shapes_name_drive_prefixes_without_authorizing_them :: proc(t: ^testing.T) {
	for row in ([?]struct {path: string, prefix, absolute: bool} {
		{`C:\a.txt`, true, true},
		{`c:/a.txt`, true, true},
		{`C:a.txt`, true, false},
		{`C:`, true, false},
		{`1:\a.txt`, false, false},
		{`\\server\share`, false, false},
		{`C:\a.txt:stream`, true, true},
		{`C:\NUL`, true, true},
		{`relative\a.txt`, false, false},
	}) {
		testing.expectf(t, winpath.has_drive_prefix(row.path) == row.prefix, "%q prefix", row.path)
		testing.expectf(t, winpath.is_drive_absolute(row.path) == row.absolute, "%q absolute", row.path)
	}
}
