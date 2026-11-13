package version

import "testing"

func TestParse(t *testing.T) {
	if parts, ok := Parse("v1.4.2"); !ok || len(parts) != 3 || parts[0] != 1 || parts[1] != 4 || parts[2] != 2 {
		t.Fatalf("v1.4.2 parsed as %v, %v", parts, ok)
	}
	for _, bad := range []string{"", "v", "1..2", "1.2-beta", "1.2.3.4.5", "one.two", "1.2 ", "-1.0", "dev"} {
		if _, ok := Parse(bad); ok {
			t.Errorf("%q parsed as a version", bad)
		}
	}
}

func TestNewer(t *testing.T) {
	cases := []struct {
		candidate, current string
		want               bool
	}{
		{"v1.10.0", "1.9.9", true}, // numbers compare as numbers, not as text
		{"1.2.1", "1.2", true},
		{"1.2", "1.2.0", false},
		{"1.99.99", "2.0.0", false},
		{"1.0.0", "1.0.0", false},
		{"2.0.0-beta", "1.0.0", false},
		{"2.0.0", "dev", false},
	}
	for _, c := range cases {
		if got := Newer(c.candidate, c.current); got != c.want {
			t.Errorf("Newer(%q, %q) = %v, want %v", c.candidate, c.current, got, c.want)
		}
	}
}
