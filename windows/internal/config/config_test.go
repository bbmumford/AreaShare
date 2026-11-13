package config

import (
	"os"
	"path/filepath"
	"testing"

	"areashare/internal/geom"
)

func TestLoadMissingFileGivesDefaults(t *testing.T) {
	c, err := Load(filepath.Join(t.TempDir(), "absent.json"))
	if err != nil {
		t.Fatalf("a missing file is an error: %v", err)
	}
	if c != Default() {
		t.Fatalf("got %+v, want the defaults", c)
	}
	if _, ok := c.Region(); ok {
		t.Fatal("the defaults claim a saved region")
	}
}

func TestSaveThenLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "config.json")
	want := Config{FPS: 60, ShowCursor: false}
	want.SetRegion(geom.RectAt(-1920, 40, 1600, 900))
	if err := Save(path, want); err != nil {
		t.Fatal(err)
	}
	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	if r, ok := got.Region(); !ok || r != geom.RectAt(-1920, 40, 1600, 900) {
		t.Fatalf("region came back as %+v (saved: %v)", r, ok)
	}
	leftovers, _ := filepath.Glob(filepath.Join(filepath.Dir(path), "*.tmp"))
	if len(leftovers) != 0 {
		t.Fatalf("temporary files left behind: %v", leftovers)
	}
}

func TestLoadRepairsUnsupportedFrameRate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"fps": 1000, "showCursor": false}`), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if c.FPS != DefaultFPS || c.ShowCursor {
		t.Fatalf("got %+v", c)
	}
}

func TestLoadCorruptFileReportsAndFallsBack(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"fps": `), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load(path)
	if err == nil {
		t.Fatal("a truncated file loaded without error")
	}
	if c != Default() {
		t.Fatalf("got %+v, want the defaults", c)
	}
}
