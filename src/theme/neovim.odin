package theme

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

NEOVIM_PLUGIN_PATTERN :: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"
NEOVIM_COLORSCHEME_PATTERN :: "^[A-Za-z0-9_.-]+$"
NEOVIM_PLUGIN_MAX_LENGTH :: 100
NEOVIM_COLORSCHEME_MAX_LENGTH :: 64

Neovim_Background :: enum {
	Auto,
	Dark,
	Light,
}

// The Neovim colorscheme a theme names, as data: the colorscheme to apply, the plugin repository that
// provides it (documentation only, so it may be empty), and the 'background' it needs when that is not
// simply the theme's own. A theme without one has an empty colorscheme. Its strings are owned by
// whoever holds the theme.
Neovim :: struct {
	plugin, colorscheme: string,
	background:          Neovim_Background,
}

@(private)
neovim_name_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
		c == '_' || c == '.' || c == '-'
}

neovim_colorscheme_valid :: proc(text: string) -> bool {
	if len(text) == 0 || len(text) > NEOVIM_COLORSCHEME_MAX_LENGTH {return false}
	for i in 0 ..< len(text) {
		if !neovim_name_byte(text[i]) {return false}
	}
	return true
}

// `owner/repository`, the form a plugin manager takes.
neovim_plugin_valid :: proc(text: string) -> bool {
	if len(text) == 0 || len(text) > NEOVIM_PLUGIN_MAX_LENGTH {return false}
	slash := strings.index_byte(text, '/')
	if slash <= 0 || slash == len(text) - 1 {return false}
	for i in 0 ..< len(text) {
		if i != slash && !neovim_name_byte(text[i]) {return false}
	}
	return true
}

// Reads the `neovim` object of a theme file. `n`'s strings and `issue` are temporary.
@(private, require_results)
neovim_parse :: proc(value: json.Value) -> (n: Neovim, issue: string) {
	object, is_object := value.(json.Object)
	if !is_object {return {}, "Expected a neovim object."}
	for key in object {
		if key != "plugin" && key != "colorscheme" && key != "background" {
			return {}, fmt.tprintf("Unknown neovim field: %s", key)
		}
	}
	plugin: json.String
	if entry, has_plugin := object["plugin"]; has_plugin {
		text, text_ok := entry.(json.String)
		if !text_ok || !neovim_plugin_valid(string(text)) {
			return {}, "Invalid neovim plugin; use owner/repository."
		}
		plugin = text
	}
	colorscheme, colorscheme_ok := object["colorscheme"].(json.String)
	if !colorscheme_ok || !neovim_colorscheme_valid(string(colorscheme)) {
		return {}, "Invalid neovim colorscheme."
	}
	if background, has_background := object["background"]; has_background {
		text, text_ok := background.(json.String)
		switch {
		case text_ok && text == "dark":
			n.background = .Dark
		case text_ok && text == "light":
			n.background = .Light
		case:
			return {}, "Neovim background must be dark or light."
		}
	}
	cloned_plugin, plugin_error := strings.clone(string(plugin), context.temp_allocator)
	cloned_colorscheme, colorscheme_error := strings.clone(string(colorscheme), context.temp_allocator)
	if plugin_error != nil || colorscheme_error != nil {return {}, "Could not allocate neovim theme."}
	n.plugin, n.colorscheme = cloned_plugin, cloned_colorscheme
	return
}

@(require_results)
neovim_clone :: proc(
	n: Neovim,
	allocator: runtime.Allocator,
) -> (
	c: Neovim,
	err: runtime.Allocator_Error,
) {
	c.background = n.background
	c.plugin = strings.clone(n.plugin, allocator) or_return
	c.colorscheme, err = strings.clone(n.colorscheme, allocator)
	if err != nil {delete(c.plugin, allocator)}
	return
}

neovim_destroy :: proc(n: Neovim, allocator: runtime.Allocator) {
	delete(n.plugin, allocator)
	delete(n.colorscheme, allocator)
}

@(private)
neovim_background_text :: proc(b: Neovim_Background) -> string {
	switch b {
	case .Auto:
		return ""
	case .Dark:
		return "dark"
	case .Light:
		return "light"
	}
	return ""
}

// Writes `"key": "value"` with the value quoted as JSON; false when it cannot be quoted.
@(require_results)
write_json_string :: proc(b: ^strings.Builder, indent, key, value, separator: string) -> bool {
	quoted_key, key_error := json.marshal(key, allocator = context.temp_allocator)
	quoted_value, value_error := json.marshal(value, allocator = context.temp_allocator)
	if key_error != nil || value_error != nil {return false}
	return write_parts(b, indent, string(quoted_key), ": ", string(quoted_value), separator) == nil
}

// The neovim object as a theme file writes it, at the top level: a trailing comma follows.
@(require_results)
neovim_write :: proc(b: ^strings.Builder, n: Neovim) -> bool {
	if n.colorscheme == "" {return true}
	background := neovim_background_text(n.background)
	if write_parts(b, "  \"neovim\": {\n") != nil {return false}
	if n.plugin != "" && !write_json_string(b, "    ", "plugin", n.plugin, ",\n") {return false}
	if !write_json_string(b, "    ", "colorscheme", n.colorscheme, background == "" ? "\n" : ",\n") {
		return false
	}
	if background != "" && !write_json_string(b, "    ", "background", background, "\n") {return false}
	return write_parts(b, "  },\n") == nil
}
