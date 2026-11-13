// Package version compares release versions such as "1.4.2", as used in tags
// ("v1.4.2") and stamped into the program at build time.
package version

import (
	"strconv"
	"strings"
)

// Parse reads a dotted version, with or without a leading "v". Only plain
// dotted numbers are versions: anything with a suffix ("1.5.0-beta") is not,
// so a pre-release is never offered as an update.
func Parse(text string) ([]int, bool) {
	text = strings.TrimPrefix(strings.TrimPrefix(text, "v"), "V")
	pieces := strings.Split(text, ".")
	if len(pieces) > 4 {
		return nil, false
	}
	parts := make([]int, 0, len(pieces))
	for _, piece := range pieces {
		if piece == "" || len(piece) > 9 || strings.Trim(piece, "0123456789") != "" {
			return nil, false
		}
		n, err := strconv.Atoi(piece)
		if err != nil {
			return nil, false
		}
		parts = append(parts, n)
	}
	return parts, true
}

// Newer reports whether candidate is a later version than current. A missing
// trailing part counts as zero, so "1.2" and "1.2.0" are the same version.
// An unreadable version on either side is never newer.
func Newer(candidate, current string) bool {
	a, ok := Parse(candidate)
	if !ok {
		return false
	}
	b, ok := Parse(current)
	if !ok {
		return false
	}
	for i := 0; i < len(a) || i < len(b); i++ {
		var x, y int
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		if x != y {
			return x > y
		}
	}
	return false
}
