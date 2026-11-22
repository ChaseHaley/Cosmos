package testkit

import "base:runtime"
import "cosmos:theme"
import "core:strings"

// The bundled theme files, compiled in so tests need no working directory.
BUNDLED_THEMES := #load_directory("../../themes")
// The folder they come from, for tests of code that scans a themes folder.
BUNDLED_THEMES_DIRECTORY :: #directory + "/../../themes"

// One bundled file's theme; `ok` is false for files that are not themes, such as the schema.
bundled_theme_file :: proc(file: runtime.Load_Directory_File) -> (t: theme.Theme, ok: bool) {
	if !strings.has_suffix(file.name, ".theme.json") {return}
	issue: string
	t, issue = theme.from_text(string(file.data))
	return t, issue == ""
}

// The bundled theme with ID `id`; a missing one is a broken test.
bundled_theme :: proc(id: string) -> theme.Theme {
	for file in BUNDLED_THEMES {
		if strings.trim_suffix(file.name, ".theme.json") != id {continue}
		if t, ok := bundled_theme_file(file); ok {return t}
	}
	panic("missing bundled theme")
}
