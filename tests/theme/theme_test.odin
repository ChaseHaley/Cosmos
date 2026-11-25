package theme_test

import "cosmos:testkit"
import "cosmos:theme"
import "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
schema_tracks_the_token_catalogue :: proc(t: ^testing.T) {
	text, ok := theme.schema_text()
	testing.expect(t, ok)
	defer delete(text)
	value, error := json.parse(text, spec = .JSON)
	testing.expect_value(t, error, json.Error.None)
	defer json.destroy_value(value)
	colors := value.(json.Object)["properties"].(json.Object)["colors"].(json.Object)
	tokens := colors["properties"].(json.Object)
	testing.expect_value(t, len(tokens), len(theme.TOKENS))
	for info in theme.TOKENS {testing.expect(t, info.key in tokens, info.key)}
	checked_in := ""
	for file in testkit.BUNDLED_THEMES {
		if file.name == "theme.schema.json" {checked_in = string(file.data)}
	}
	testing.expect_value(t, checked_in, text)
}

@(test)
every_bundled_theme_parses_without_links_and_differs_from_the_default :: proc(t: ^testing.T) {
	count := 0
	for file in testkit.BUNDLED_THEMES {
		if !strings.has_suffix(file.name, ".theme.json") {continue}
		count += 1
		layer, issue := theme.file_parse(string(file.data))
		testing.expect_value(t, issue, "")
		testing.expect(t, layer.linked == {}, file.name)
		testing.expect(t, layer.external, file.name)
		resolved := theme.resolve(nil, &layer)
		if layer.id != theme.DEFAULT_ID {testing.expect(t, resolved != theme.default(), file.name)}
	}
	testing.expect(t, count >= 20)
}

@(test)
a_follower_takes_its_target_and_moves_with_it :: proc(t: ^testing.T) {
	base := theme.Layer {
		id = "base",
	}
	base.colors[.Accent] = {10, 20, 30, 255}
	base.overrides += {.Accent}
	child := theme.Layer {
		id   = "child",
		base = "base",
	}
	value, problem := theme.value_parse(.Cursor_Text, "accent", .Strict)
	testing.expect_value(t, problem, theme.Value_Problem.None)
	testing.expect(t, value.linked)
	child.linked += {.Cursor_Text}
	child.target[.Cursor_Text] = value.target
	child.overrides += {.Cursor_Text}
	layers := []theme.Layer{base, child}
	resolved := theme.resolve(layers, &layers[1])
	testing.expect_value(t, resolved.colors[.Cursor_Text], theme.Color{10, 20, 30, 255})
	testing.expect_value(t, resolved.colors[.Accent], theme.Color{10, 20, 30, 255})
}

@(test)
a_loop_of_followers_names_itself_and_falls_back :: proc(t: ^testing.T) {
	layer := theme.Layer {
		id = "loop",
	}
	layer.linked += {.Accent, .Border}
	layer.target[.Accent] = .Border
	layer.target[.Border] = .Accent
	layer.overrides += {.Accent, .Border}
	resolved, loop := theme.resolve_checked(nil, &layer)
	testing.expect_value(t, loop, "accent -> border -> accent")
	fallback := theme.default()
	testing.expect_value(t, resolved.colors[.Accent], fallback.colors[.Accent])
	testing.expect(t, .Accent not_in resolved.linked)
}

@(test)
values_refuse_what_cannot_be_followed :: proc(t: ^testing.T) {
	_, self := theme.value_parse(.Accent, "accent", .Strict)
	testing.expect_value(t, self, theme.Value_Problem.Self_Link)
	_, optional := theme.value_parse(.Accent, "cursor", .Strict)
	testing.expect_value(t, optional, theme.Value_Problem.Optional_Link)
	_, unknown := theme.value_parse(.Accent, "no_such_color", .Strict)
	testing.expect_value(t, unknown, theme.Value_Problem.Unknown_Link)
	_, invalid := theme.value_parse(.Accent, "#12", .Strict)
	testing.expect_value(t, invalid, theme.Value_Problem.Invalid)
}

@(test)
a_written_file_reads_back_as_the_same_theme :: proc(t: ^testing.T) {
	source := testkit.bundled_theme("tokyonight-storm")
	source.linked += {.Cursor_Text}
	source.target[.Cursor_Text] = .Accent
	text, ok := theme.file_text("round-trip", source, "Round trip", neovim = {colorscheme = "tokyonight"})
	testing.expect(t, ok)
	defer delete(text)
	layer, issue := theme.file_parse(text)
	testing.expect_value(t, issue, "")
	testing.expect_value(t, layer.id, "round-trip")
	testing.expect_value(t, layer.name, "Round trip")
	testing.expect_value(t, layer.neovim.colorscheme, "tokyonight")
	testing.expect(t, .Cursor_Text in layer.linked)
	resolved := theme.resolve(nil, &layer)
	testing.expect_value(t, resolved.colors[.Cursor_Text], resolved.colors[.Accent])
	testing.expect_value(t, resolved.colors[.Window], source.colors[.Window])
}

@(test)
ids_follow_the_family_grammar :: proc(t: ^testing.T) {
	testing.expect(t, theme.id_valid("studio-dark"))
	testing.expect(t, theme.id_valid("a_1"))
	testing.expect(t, !theme.id_valid(""))
	testing.expect(t, !theme.id_valid("-lead"))
	testing.expect(t, !theme.id_valid("Upper"))
	testing.expect(t, !theme.id_valid(strings.repeat("a", theme.ID_MAX_LENGTH + 1, context.temp_allocator)))
	testing.expect_value(t, theme.legacy_base("studio-light"), "studio-light")
	testing.expect_value(t, theme.legacy_base("tokyonight-moon-light"), "tokyonight-day")
}

// A light system's default is the bundled light theme, and the default stays the dark one.
@(test)
the_light_default_is_the_bundled_light_theme :: proc(t: ^testing.T) {
	light := theme.default(dark = false)
	testing.expect(t, light.light, "the light default has a dark window")
	testing.expect(t, !theme.default().light, "the default is not dark")
	found := false
	for file in testkit.BUNDLED_THEMES {
		if file.name != "studio-light.theme.json" {continue}
		found = true
		bundled, issue := theme.from_text(string(file.data))
		testing.expect_value(t, issue, "")
		testing.expect_value(t, light.colors[.Window], bundled.colors[.Window])
		testing.expect_value(t, light.colors[.Accent], bundled.colors[.Accent])
	}
	testing.expect(t, found, "studio-light is not bundled")
}
