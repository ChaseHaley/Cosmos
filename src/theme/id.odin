package theme

import "base:runtime"
import "core:fmt"
import "core:strings"

// The longest theme ID, and the pattern every ID matches.
ID_MAX_LENGTH :: 32
ID_PATTERN :: "^[a-z0-9][a-z0-9_-]*$"

// Whether `id` can name a theme: lowercase letters, digits, `_` and `-`, not starting with `_` or `-`.
id_valid :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > ID_MAX_LENGTH {return false}
	if id[0] == '-' || id[0] == '_' {return false}
	for i in 0 ..< len(id) {
		c := id[i]
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {return false}
	}
	return true
}

// Built-in themes were once a name plus a dark or light mode, and bases named a variant such as
// tokyonight-storm-dark. Each now is one theme file; this maps the old pair to that file's ID.
legacy_id :: proc(name, mode: string) -> (id: string, legacy: bool) {
	switch name {
	case "studio", "tide", "ember":
		return fmt.tprintf("%s-%s", name, mode == "light" ? "light" : "dark"), true
	case "tokyonight-night", "tokyonight-storm", "tokyonight-moon":
		return mode == "light" ? "tokyonight-day" : name, true
	}
	return name, false
}

// A base written before built-in themes became files, such as tokyonight-moon-light, as its file ID.
legacy_base :: proc(base: string) -> string {
	for mode in ([?]string{"dark", "light"}) {
		if !strings.has_suffix(base, mode) || len(base) <= len(mode) + 1 {continue}
		name := base[:len(base) - len(mode) - 1]
		if id, legacy := legacy_id(name, mode); legacy {return id}
	}
	return base
}

@(private)
write_parts :: proc(b: ^strings.Builder, parts: ..string) -> runtime.Allocator_Error {
	for part in parts {
		if strings.write_string(b, part) != len(part) {return .Out_Of_Memory}
	}
	return nil
}
