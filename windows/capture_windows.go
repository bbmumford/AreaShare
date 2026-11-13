package main

import (
	"unsafe"

	"areashare/internal/geom"
)

// capture holds the latest copy of the shared region in a memory bitmap. The
// mirror window paints from it, so the picture survives between refreshes and
// stays put while sharing is paused.
type capture struct {
	dc     uintptr // memory device context the bitmap is selected into
	bitmap uintptr
	stock  uintptr // the bitmap the context came with, restored before deletion
	size   geom.Size

	// hotspots remembers each pointer shape's hotspot, which costs two
	// bitmap allocations to ask for and never changes for a given handle.
	hotspots map[uintptr]geom.Point
}

// resize makes the bitmap match the region's size, starting black. It reports
// whether the bitmap is usable.
func (c *capture) resize(s geom.Size) bool {
	if c.bitmap != 0 && c.size == s {
		return true
	}
	screen := getDC(0)
	if screen == 0 {
		return false
	}
	defer releaseDC(0, screen)
	if c.dc == 0 {
		if c.dc, _, _ = procCreateCompatibleDC.Call(screen); c.dc == 0 {
			return false
		}
	}
	bitmap, _, _ := procCreateCompatibleBitmap.Call(screen, uintptr(s.W), uintptr(s.H))
	if bitmap == 0 {
		return false
	}
	old := selectObject(c.dc, bitmap)
	if c.bitmap == 0 {
		c.stock = old
	} else {
		deleteObject(c.bitmap)
	}
	c.bitmap, c.size = bitmap, s
	procPatBlt.Call(c.dc, 0, 0, uintptr(s.W), uintptr(s.H), ropBlackness)
	return true
}

// grab copies the region's pixels from the screen into the bitmap and, when
// asked, draws the pointer on top, since a screen copy does not include it.
func (c *capture) grab(region geom.Rect, withCursor bool) {
	if c.bitmap == 0 {
		return
	}
	screen := getDC(0)
	if screen == 0 {
		return
	}
	ok := bitBlt(c.dc, 0, 0, c.size.W, c.size.H, screen, region.Left, region.Top, ropSrcCopy|ropCaptureBlt)
	releaseDC(0, screen)
	if ok && withCursor {
		c.drawCursor(region)
	}
}

func (c *capture) drawCursor(region geom.Rect) {
	ci := cursorInfo{size: uint32(unsafe.Sizeof(cursorInfo{}))}
	if ok, _, _ := procGetCursorInfo.Call(uintptr(unsafe.Pointer(&ci))); ok == 0 {
		return
	}
	if ci.flags&cursorShowing == 0 || ci.cursor == 0 {
		return
	}
	// Pointer shapes are at most a few hundred pixels across; anything
	// farther from the region than that cannot reach into it.
	if !region.Inflate(512).Contains(ci.pos) {
		return
	}
	hot := c.hotspot(ci.cursor)
	procDrawIconEx.Call(c.dc,
		uintptr(ci.pos.X-region.Left-hot.X), uintptr(ci.pos.Y-region.Top-hot.Y),
		ci.cursor, 0, 0, 0, 0, diNormal)
}

func (c *capture) hotspot(cursor uintptr) geom.Point {
	if p, ok := c.hotspots[cursor]; ok {
		return p
	}
	var p geom.Point
	var ii iconInfo
	if ok, _, _ := procGetIconInfo.Call(cursor, uintptr(unsafe.Pointer(&ii))); ok != 0 {
		p = geom.Point{X: int32(ii.xHotspot), Y: int32(ii.yHotspot)}
		deleteObject(ii.mask)
		deleteObject(ii.color)
	}
	if c.hotspots == nil || len(c.hotspots) > 256 {
		c.hotspots = make(map[uintptr]geom.Point)
	}
	c.hotspots[cursor] = p
	return p
}

// paint copies the bitmap to a window's device context.
func (c *capture) paint(hdc uintptr) {
	if c.bitmap != 0 {
		bitBlt(hdc, 0, 0, c.size.W, c.size.H, c.dc, 0, 0, ropSrcCopy)
	}
}

func (c *capture) close() {
	if c.dc == 0 {
		return
	}
	if c.bitmap != 0 {
		selectObject(c.dc, c.stock)
		deleteObject(c.bitmap)
	}
	procDeleteDC.Call(c.dc)
	*c = capture{}
}
