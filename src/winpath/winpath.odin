package winpath

// Windows path shapes: facts about spellings only. Callers that open, read or run a path keep their own
// admission policies on top of them.

@(require_results)
is_separator :: proc(c: u8) -> bool {
	return c == '\\' || c == '/'
}

// An ASCII letter followed by a colon. A shape, not an authorization: drive-relative "C:name"
// matches too.
@(require_results)
has_drive_prefix :: proc(path: string) -> bool {
	if len(path) < 2 || path[1] != ':' {return false}
	c := path[0]
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// A drive prefix followed by a separator, with no check of the rest.
@(require_results)
is_drive_absolute :: proc(path: string) -> bool {
	return len(path) >= 3 && has_drive_prefix(path) && is_separator(path[2])
}
