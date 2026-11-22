package weburl

// Allowed reports whether a target may be opened as a web page. Only plain http and https URLs pass:
// the authority must exist and look like a host, and Windows path shapes, credentials, control
// characters and backslashes are refused. platform.open_url opens nothing else, and an app that detects
// links uses the same test, so a target can never be clickable but unopenable, or openable but invisible.
@(require_results)
allowed :: proc(uri: string) -> bool {
	if len(uri) < 8 {
		return false
	}
	for c in uri {
		if c <= 0x20 ||
		   c == 0x7f ||
		   (c >= 0x80 && c <= 0x9f) ||
		   c == 0x00a0 ||
		   c == 0x2028 ||
		   c == 0x2029 ||
		   c == '\\' ||
		   c == '"' ||
		   c == '<' ||
		   c == '>' {
			return false
		}
	}
	separator := -1
	for i := 0; i + 2 < len(uri); i += 1 {
		if uri[i] == ':' && uri[i + 1] == '/' && uri[i + 2] == '/' {
			separator = i
			break
		}
	}
	if separator <= 0 {
		return false
	}
	if !scheme_is(uri[:separator], "http") && !scheme_is(uri[:separator], "https") {
		return false
	}
	rest := uri[separator + 3:]
	authority_end := len(rest)
	for c, i in rest {
		if c == '/' || c == '?' || c == '#' {
			authority_end = i
			break
		}
	}
	authority := rest[:authority_end]
	if authority == "" {
		return false
	}
	// A drive-letter authority is a Windows path wearing a URL scheme, not a web host.
	if len(authority) == 2 && authority[1] == ':' {
		return false
	}
	if authority[0] == ':' || authority[0] == '.' || authority[len(authority) - 1] == ':' {
		return false
	}
	has_alphanumeric, bracket_open, bracket_close := false, false, false
	for c in authority {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
			has_alphanumeric = true
		case c == '-', c == '.', c == '_', c == ':':
		case c == '[':
			bracket_open = true
		case c == ']':
			bracket_close = true
		case:
			return false
		}
	}
	return has_alphanumeric && bracket_open == bracket_close
}

// Whether `value` spells `expected`, a lowercase scheme or prefix, in any ASCII case.
@(require_results)
scheme_is :: proc(value, expected: string) -> bool {
	if len(value) != len(expected) {
		return false
	}
	for i in 0 ..< len(value) {
		c := value[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != expected[i] {
			return false
		}
	}
	return true
}
