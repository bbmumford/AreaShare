// Package config stores the settings AreaShare carries between runs: where
// the shared region is, how often it is refreshed, and whether the pointer is
// drawn into the copy.
package config

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"

	"areashare/internal/geom"
)

// FrameRates are the refresh rates offered in the menu, in frames per second.
var FrameRates = []int{15, 30, 60}

// DefaultFPS is used when no rate, or an unsupported one, is stored.
const DefaultFPS = 30

// Config is the persisted state. A zero Width or Height means no region has
// been saved yet and the caller should pick a default for the current
// displays.
type Config struct {
	X          int32 `json:"x"`
	Y          int32 `json:"y"`
	Width      int32 `json:"width"`
	Height     int32 `json:"height"`
	FPS        int   `json:"fps"`
	ShowCursor bool  `json:"showCursor"`
}

// Default returns the settings for a first run.
func Default() Config {
	return Config{FPS: DefaultFPS, ShowCursor: true}
}

// Region returns the saved region and whether one was saved.
func (c Config) Region() (geom.Rect, bool) {
	if c.Width <= 0 || c.Height <= 0 {
		return geom.Rect{}, false
	}
	return geom.RectAt(c.X, c.Y, c.Width, c.Height), true
}

// SetRegion records r as the region to restore next run.
func (c *Config) SetRegion(r geom.Rect) {
	c.X, c.Y, c.Width, c.Height = r.Left, r.Top, r.W(), r.H()
}

// normalize replaces values the menu could not have produced.
func (c *Config) normalize() {
	for _, f := range FrameRates {
		if c.FPS == f {
			return
		}
	}
	c.FPS = DefaultFPS
}

// Path returns the settings file location under the user's configuration
// directory (%AppData% on Windows).
func Path() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "AreaShare", "config.json"), nil
}

// Load reads the settings file. A missing file is not an error: the defaults
// are returned. A file that cannot be parsed returns the defaults together
// with the error, so the caller can carry on and report it.
func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Default(), nil
	}
	if err != nil {
		return Default(), err
	}
	c := Default()
	if err := json.Unmarshal(data, &c); err != nil {
		return Default(), err
	}
	c.normalize()
	return c, nil
}

// Save writes the settings file, replacing it in one step so an interrupted
// write cannot leave a half-written file behind.
func Save(path string, c Config) error {
	c.normalize()
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "config-*.tmp")
	if err != nil {
		return err
	}
	_, err = tmp.Write(append(data, '\n'))
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), path)
	}
	if err != nil {
		os.Remove(tmp.Name())
	}
	return err
}
