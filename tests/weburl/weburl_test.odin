package weburl_test

import "core:testing"
import "cosmos:weburl"

@(test)
allowed_accepts_only_plain_web_targets :: proc(t: ^testing.T) {
	cases := [?]struct {
		uri, note: string,
		allowed:   bool,
	} {
		{"https://example.com", "https", true},
		{"http://example.com/path?q=1#frag", "http with path and query", true},
		{"HTTPS://EXAMPLE.COM", "case-insensitive scheme", true},
		{"http://127.0.0.1:8080/link", "loopback with port", true},
		{"http://[::1]:8080/", "IPv6 literal", true},
		{"file:///C:/Windows/win.ini", "file scheme", false},
		{"ssh://example.com/repo", "ssh scheme", false},
		{"javascript:alert(1)", "script scheme", false},
		{"data:text/html,hello", "data scheme", false},
		{"mailto:someone@example.com", "mail scheme", false},
		{"ftp://example.com/file", "ftp scheme", false},
		{`\\server\share\file`, "UNC path", false},
		{"//example.com/path", "protocol-relative path", false},
		{`http://\\server\share`, "backslash authority", false},
		{"http://C:/Windows", "drive-letter authority", false},
		{"http://example.com:80", "port", true},
		{"http://example.com:", "empty port", false},
		{"http://", "empty authority", false},
		{"http:///path", "path without authority", false},
		{"http://.example.com", "leading dot", false},
		{"http://user@example.com", "credentials", false},
		{"http://exa mple.com", "space", false},
		{"http://example.com/\x00", "NUL", false},
		{"http://example.com/\t", "tab", false},
		{"http://example.com/\u0085", "C1 control", false},
		{"http://example.com/\u2028", "line separator", false},
		{"http://example.com/\u00a0", "non-breaking space", false},
		{"https://example.com/a\\b", "backslash in path", false},
		{"", "empty", false},
		{"C:\\Users\\file.txt", "plain path", false},
	}
	for c in cases {
		testing.expectf(
			t,
			weburl.allowed(c.uri) == c.allowed,
			"%s (%q): expected allowed=%t",
			c.note,
			c.uri,
			c.allowed,
		)
	}
}
