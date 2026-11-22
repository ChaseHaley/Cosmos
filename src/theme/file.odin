package theme

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

FILE_MAX_BYTES :: 64 * 1024
FILE_SIZE_NOTICE :: "Theme file exceeds 64 KiB."

// The top-level fields of a theme file, in the order the schema lists them.
Field :: enum {
	Schema,
	Version,
	Id,
	Name,
	Author,
	Description,
	Base,
	Neovim,
	Colors,
}

Field_Kind :: enum {
	String,
	// The format version, which must be 1.
	Version,
	// The neovim object, checked by neovim_parse.
	Neovim,
	// The colors object, checked token by token.
	Colors,
}

Field_Info :: struct {
	key:      string,
	kind:     Field_Kind,
	required: bool,
}

// What file_parse accepts and schema_text describes at the top level of a theme file.
@(rodata)
FIELDS := [Field]Field_Info {
	.Schema      = {key = "$schema", kind = .String},
	.Version     = {key = "version", kind = .Version, required = true},
	.Id          = {key = "id", kind = .String, required = true},
	.Name        = {key = "name", kind = .String},
	.Author      = {key = "author", kind = .String},
	.Description = {key = "description", kind = .String},
	.Base        = {key = "base", kind = .String},
	.Neovim      = {key = "neovim", kind = .Neovim},
	.Colors      = {key = "colors", kind = .Colors, required = true},
}

@(private)
field_find :: proc(key: string) -> (Field_Info, bool) {
	for info in FIELDS {if info.key == key {return info, true}}
	return {}, false
}

@(require_results)
file_parse :: proc(text: string) -> (theme: Layer, issue: string) {
	if len(text) > FILE_MAX_BYTES {return {}, FILE_SIZE_NOTICE}
	lexer := json.make_tokenizer(text, .JSON)
	depth, completed := 0, false
	previous := json.Token_Kind.Invalid
	for {
		token, token_error := json.get_token(&lexer)
		if token.kind == .EOF {break}
		if token_error != .None {return {}, "Invalid JSON theme file."}
		if completed {return {}, "Unexpected content after theme object."}
		if token.kind == .Open_Brace || token.kind == .Open_Bracket {depth += 1}
		if depth > 4 {return {}, "Theme JSON nesting is too deep."}
		if token.kind == .Close_Brace || token.kind == .Close_Bracket {
			if previous == .Comma {return {}, "Trailing commas are not valid JSON."}
			depth -= 1
			if depth == 0 {completed = true}
		}
		if token.kind == .String && token.text == `""` &&
		   (previous == .Open_Brace || previous == .Comma) {return {}, "Empty theme keys are invalid."}
		previous = token.kind
	}
	value, error := json.parse(text, spec = .JSON, allocator = context.temp_allocator)
	if error != .None {return {}, "Invalid JSON theme file."}
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !object_ok {return {}, "Expected a theme object."}
	for key, entry in object {
		info, known := field_find(key)
		if !known {return {}, fmt.tprintf("Unknown theme field: %s", key)}
		switch info.kind {
		case .String:
			if _, ok := entry.(json.String); !ok {return {}, "Theme metadata must be strings."}
		case .Version:
			if version, ok := entry.(json.Float); !ok || version != 1 {
				return {}, "Expected theme version 1."
			}
		case .Colors, .Neovim:
		}
	}
	id, id_ok := object["id"].(json.String)
	version, version_ok := object["version"].(json.Float)
	colors, colors_ok := object["colors"].(json.Object)
	if !id_ok || !id_valid(string(id)) {return {}, "Invalid theme ID."}
	if !version_ok || version != 1 {return {}, "Expected theme version 1."}
	if !colors_ok {return {}, "Expected a colors object."}
	if base, has_base := object["base"].(json.String); has_base {
		if !id_valid(string(base)) {return {}, "Invalid base theme ID."}
		// Temporary like the ID below.
		cloned, clone_error := strings.clone(legacy_base(string(base)), context.temp_allocator)
		if clone_error != nil {return {}, "Could not allocate base theme ID."}
		theme.base = cloned
	}
	if name, has_name := object["name"].(json.String); has_name && name != "" {
		cloned, clone_error := strings.clone(string(name), context.temp_allocator)
		if clone_error != nil {return {}, "Could not allocate theme name."}
		theme.name = cloned
	}
	for key, entry in colors {
		token, known := token_find(key)
		if !known {return {}, fmt.tprintf("Unknown theme color: %s", key)}
		color_text, ok := entry.(json.String)
		if !ok {return {}, fmt.tprintf("Expected a color string for %s", key)}
		value, problem := value_parse(token, string(color_text), .Strict)
		if problem != .None {
			if clause := link_issue(token, string(color_text), problem); clause != "" {
				return {}, fmt.tprintf("Invalid theme color: %s, %s", key, clause)
			}
			return {}, fmt.tprintf("Invalid theme color: %s", key)
		}
		theme.colors[token] = value.color
		if value.linked {theme.linked += {token}; theme.target[token] = value.target}
		theme.overrides += {token}
	}
	if loop := loop_text(theme.linked, &theme.target); loop != "" {
		return {}, fmt.tprintf("Theme colors follow each other in a loop: %s", loop)
	}
	if neovim, has_neovim := object["neovim"]; has_neovim {
		neovim_theme, neovim_issue := neovim_parse(neovim)
		if neovim_issue != "" {return {}, neovim_issue}
		theme.neovim = neovim_theme
	}
	// The caller consumes these temporary IDs before the next scratch reset.
	cloned, clone_error := strings.clone(string(id), context.temp_allocator)
	if clone_error != nil {return {}, "Could not allocate theme ID."}
	theme.id = cloned
	theme.base_set, theme.external = true, true
	return
}

// The bundled themes beside the running executable, in its `themes` folder. Temporary.
@(require_results)
bundled_directory :: proc() -> string {
	path, error := os.get_executable_directory(context.temp_allocator)
	if error != nil {return ""}
	return fmt.tprintf("%s/themes", path)
}

// A complete theme file: every color of `theme` in token order, so it needs no base. A color that
// follows another is written as that color's key. Empty metadata is left out, and so is `neovim`
// without a colorscheme.
@(require_results)
file_text :: proc(
	id: string,
	theme: Theme,
	name := "",
	description := "",
	neovim := Neovim{},
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	if !id_valid(id) {return "", false}
	builder, error := strings.builder_make(context.temp_allocator)
	if error != nil {return "", false}
	defer strings.builder_destroy(&builder)
	if write_parts(&builder, "{\n  \"$schema\": \"./theme.schema.json\",\n  \"version\": 1,\n") != nil ||
	   !write_json_string(&builder, "  ", "id", id, ",\n") {return "", false}
	if name != "" && !write_json_string(&builder, "  ", "name", name, ",\n") {return "", false}
	if description != "" && !write_json_string(&builder, "  ", "description", description, ",\n") {
		return "", false
	}
	if !neovim_write(&builder, neovim) {return "", false}
	if write_parts(&builder, "  \"colors\": {\n") != nil {return "", false}
	for info, token in TOKENS {
		separator := token == max(Token) ? "\n" : ",\n"
		linked := token in theme.linked
		value := value_text(token, {theme.colors[token], theme.target[token], linked})
		if !write_json_string(&builder, "    ", info.key, value, separator) {return "", false}
	}
	if write_parts(&builder, "  }\n}\n") != nil {return "", false}
	text, clone_error := strings.clone(strings.to_string(builder), allocator)
	return text, clone_error == nil
}
