package theme_schema

import "cosmos:theme"
import "core:os"

// Writes the theme file schema beside the bundled themes; run from the repository root.
main :: proc() {
	text, ok := theme.schema_text()
	if !ok {os.exit(1)}
	defer delete(text)
	if error := os.write_entire_file("themes/theme.schema.json", transmute([]u8)text); error != nil {
		os.exit(1)
	}
}
