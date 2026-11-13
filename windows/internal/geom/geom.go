// Package geom holds the screen geometry AreaShare needs: where the frame
// sits around the shared region, which part of the frame the pointer is on,
// how a drag changes the region, and where the mirror window can live without
// appearing inside its own capture. It has no operating-system dependencies so
// every rule can be tested on any platform.
package geom

// Point is a position in physical screen pixels.
type Point struct{ X, Y int32 }

// Size is a width and height in physical pixels.
type Size struct{ W, H int32 }

// Rect is a half-open rectangle in physical screen pixels. Its field order
// matches the Win32 RECT structure, so a *Rect can be handed to the system
// directly.
type Rect struct{ Left, Top, Right, Bottom int32 }

// RectAt builds a rectangle from an origin and a size.
func RectAt(x, y, w, h int32) Rect { return Rect{x, y, x + w, y + h} }

func (r Rect) W() int32      { return r.Right - r.Left }
func (r Rect) H() int32      { return r.Bottom - r.Top }
func (r Rect) Size() Size    { return Size{r.W(), r.H()} }
func (r Rect) Empty() bool   { return r.Right <= r.Left || r.Bottom <= r.Top }
func (r Rect) Origin() Point { return Point{r.Left, r.Top} }

// Center returns the middle of the rectangle, rounded towards the origin.
func (r Rect) Center() Point {
	return Point{r.Left + r.W()/2, r.Top + r.H()/2}
}

// Offset returns the rectangle moved by (dx, dy).
func (r Rect) Offset(dx, dy int32) Rect {
	return Rect{r.Left + dx, r.Top + dy, r.Right + dx, r.Bottom + dy}
}

// Inflate returns the rectangle grown by d on every side.
func (r Rect) Inflate(d int32) Rect {
	return Rect{r.Left - d, r.Top - d, r.Right + d, r.Bottom + d}
}

// Contains reports whether p lies inside the rectangle.
func (r Rect) Contains(p Point) bool {
	return p.X >= r.Left && p.X < r.Right && p.Y >= r.Top && p.Y < r.Bottom
}

// ContainsRect reports whether o lies entirely inside the rectangle.
func (r Rect) ContainsRect(o Rect) bool {
	return o.Left >= r.Left && o.Top >= r.Top && o.Right <= r.Right && o.Bottom <= r.Bottom
}

// Intersect returns the overlap of two rectangles; the result is Empty when
// they do not overlap.
func (r Rect) Intersect(o Rect) Rect {
	return Rect{max(r.Left, o.Left), max(r.Top, o.Top), min(r.Right, o.Right), min(r.Bottom, o.Bottom)}
}

// Intersects reports whether two rectangles share at least one pixel.
func (r Rect) Intersects(o Rect) bool { return !r.Intersect(o).Empty() }

// Union returns the smallest rectangle covering both. An empty operand is
// ignored.
func (r Rect) Union(o Rect) Rect {
	if r.Empty() {
		return o
	}
	if o.Empty() {
		return r
	}
	return Rect{min(r.Left, o.Left), min(r.Top, o.Top), max(r.Right, o.Right), max(r.Bottom, o.Bottom)}
}

func (r Rect) area() int64 {
	if r.Empty() {
		return 0
	}
	return int64(r.W()) * int64(r.H())
}

// FitInto returns r moved, and shrunk only if it has to be, so that it lies
// inside bounds. The origin is kept where possible.
func (r Rect) FitInto(bounds Rect) Rect {
	w, h := min(r.W(), bounds.W()), min(r.H(), bounds.H())
	x := max(bounds.Left, min(r.Left, bounds.Right-w))
	y := max(bounds.Top, min(r.Top, bounds.Bottom-h))
	return RectAt(x, y, w, h)
}

// CenterIn returns a rectangle of the given size centred in bounds, shrunk to
// bounds if it is larger.
func CenterIn(bounds Rect, s Size) Rect {
	w, h := min(s.W, bounds.W()), min(s.H, bounds.H())
	return RectAt(bounds.Left+(bounds.W()-w)/2, bounds.Top+(bounds.H()-h)/2, w, h)
}

// Bounds returns the union of all monitors: the virtual screen.
func Bounds(monitors []Rect) Rect {
	var b Rect
	for _, m := range monitors {
		b = b.Union(m)
	}
	return b
}

// BestMonitor returns the monitor that shows most of r, or the nearest one
// when r is entirely off screen. ok is false only when there are no monitors.
func BestMonitor(r Rect, monitors []Rect) (best Rect, ok bool) {
	var bestArea int64 = -1
	var bestDist int64
	c := r.Center()
	for _, m := range monitors {
		a := m.Intersect(r).area()
		d := dist2(c, m.Center())
		if a > bestArea || (a == bestArea && d < bestDist) {
			best, bestArea, bestDist, ok = m, a, d, true
		}
	}
	return best, ok
}

func dist2(a, b Point) int64 {
	dx, dy := int64(a.X-b.X), int64(a.Y-b.Y)
	return dx*dx + dy*dy
}

// Metrics are the frame's dimensions in physical pixels for one display
// scale.
type Metrics struct {
	Border int32 // thickness of the ring drawn around the region
	TabW   int32 // preferred width of the grab tab
	TabH   int32 // height of the grab tab
	Corner int32 // length along each edge that resizes diagonally
	MinW   int32 // smallest region width a drag can produce
	MinH   int32 // smallest region height a drag can produce
}

// MetricsForDPI scales the frame's design dimensions (given at 96 DPI) to a
// monitor's DPI.
func MetricsForDPI(dpi int32) Metrics {
	if dpi <= 0 {
		dpi = 96
	}
	s := func(v int32) int32 { return (v*dpi + 48) / 96 }
	return Metrics{Border: s(6), TabW: s(230), TabH: s(26), Corner: s(22), MinW: s(160), MinH: s(120)}
}

// TabSide says where the grab tab is attached.
type TabSide int

const (
	TabAbove  TabSide = iota // outside the ring, above its top-left corner
	TabBelow                 // outside the ring, below its bottom-left corner
	TabInside                // inside the region's top-left corner
)

// Layout is the frame window's geometry for one region, in screen
// coordinates. The ring is Outer minus Region; the tab is a separate block.
type Layout struct {
	Region Rect // the shared pixels; nothing of the frame is drawn here unless Side is TabInside
	Outer  Rect // Region grown by the border
	Tab    Rect
	Window Rect // bounding box of ring and tab: the frame window's rectangle
	Side   TabSide
}

// Compute lays the frame out around region. The tab goes above the ring when
// the monitor has room for it there, otherwise below, and only inside the
// region when the region spans the monitor's full height.
func Compute(region, monitor Rect, m Metrics) Layout {
	l := Layout{Region: region, Outer: region.Inflate(m.Border)}
	w := min(m.TabW, l.Outer.W())
	above := RectAt(l.Outer.Left, l.Outer.Top-m.TabH, w, m.TabH)
	below := RectAt(l.Outer.Left, l.Outer.Bottom, w, m.TabH)
	switch {
	case above.Top >= monitor.Top:
		l.Tab, l.Side = above, TabAbove
	case below.Bottom <= monitor.Bottom:
		l.Tab, l.Side = below, TabBelow
	default:
		l.Tab, l.Side = RectAt(region.Left, region.Top, min(m.TabW, region.W()), min(m.TabH, region.H())), TabInside
	}
	l.Window = l.Outer.Union(l.Tab)
	return l
}

// Zone names the part of the frame under the pointer.
type Zone int

const (
	ZoneNone Zone = iota
	ZoneMove
	ZoneLeft
	ZoneRight
	ZoneTop
	ZoneBottom
	ZoneTopLeft
	ZoneTopRight
	ZoneBottomLeft
	ZoneBottomRight
)

// Hit returns the zone at screen point p: the tab moves the region, the ring
// resizes it, and the ends of each ring edge resize diagonally.
func (l Layout) Hit(p Point, m Metrics) Zone {
	if l.Tab.Contains(p) {
		return ZoneMove
	}
	if !l.Outer.Contains(p) || l.Region.Contains(p) {
		return ZoneNone
	}
	cx := min(m.Corner, l.Outer.W()/3)
	cy := min(m.Corner, l.Outer.H()/3)
	left, right := p.X < l.Outer.Left+cx, p.X >= l.Outer.Right-cx
	top, bottom := p.Y < l.Outer.Top+cy, p.Y >= l.Outer.Bottom-cy
	switch {
	case top && left:
		return ZoneTopLeft
	case top && right:
		return ZoneTopRight
	case bottom && left:
		return ZoneBottomLeft
	case bottom && right:
		return ZoneBottomRight
	case p.X < l.Region.Left:
		return ZoneLeft
	case p.X >= l.Region.Right:
		return ZoneRight
	case p.Y < l.Region.Top:
		return ZoneTop
	default:
		return ZoneBottom
	}
}

// Drag is a move or resize in progress: the zone that was grabbed, the region
// as it was at that moment, and where the pointer was.
type Drag struct {
	Zone   Zone
	Start  Rect
	Anchor Point
}

// Apply returns the region for the pointer's current position. The region
// never leaves bounds and never gets smaller than the metrics' minimum.
func (d Drag) Apply(cursor Point, bounds Rect, m Metrics) Rect {
	dx, dy := cursor.X-d.Anchor.X, cursor.Y-d.Anchor.Y
	r := d.Start
	if d.Zone == ZoneMove {
		return r.Offset(dx, dy).FitInto(bounds)
	}
	minW, minH := min(m.MinW, r.W()), min(m.MinH, r.H())
	switch d.Zone {
	case ZoneLeft, ZoneTopLeft, ZoneBottomLeft:
		r.Left = max(bounds.Left, min(r.Left+dx, r.Right-minW))
	case ZoneRight, ZoneTopRight, ZoneBottomRight:
		r.Right = min(bounds.Right, max(r.Right+dx, r.Left+minW))
	}
	switch d.Zone {
	case ZoneTop, ZoneTopLeft, ZoneTopRight:
		r.Top = max(bounds.Top, min(r.Top+dy, r.Bottom-minH))
	case ZoneBottom, ZoneBottomLeft, ZoneBottomRight:
		r.Bottom = min(bounds.Bottom, max(r.Bottom+dy, r.Top+minH))
	}
	return r
}

// Resized returns region changed to size s about its centre, kept inside
// bounds.
func Resized(region Rect, s Size, bounds Rect) Rect {
	c := region.Center()
	return RectAt(c.X-s.W/2, c.Y-s.H/2, s.W, s.H).FitInto(bounds)
}

// PlaceMirror chooses where the mirror window goes. The mirror shows a live
// copy of the region, so if any of it were visible inside avoid (the region
// plus its frame) the capture would contain itself. cur is kept when it is
// already a good spot; otherwise the mirror goes to the monitor corner
// farthest from the region, preferring monitors the region does not touch.
// When no monitor has room, it is parked just past the right edge of the
// virtual screen and parked is true.
func PlaceMirror(cur Rect, size Size, avoid Rect, monitors []Rect) (pos Rect, parked bool) {
	fits := func(r Rect) bool {
		if r.Intersects(avoid) {
			return false
		}
		for _, m := range monitors {
			if m.ContainsRect(r) {
				return true
			}
		}
		return false
	}
	if cur.Size() == size && fits(cur) {
		return cur, false
	}
	var best Rect
	bestClear, bestDist, found := false, int64(-1), false
	target := avoid.Center()
	for _, m := range monitors {
		if m.W() < size.W || m.H() < size.H {
			continue
		}
		clear := !m.Intersects(avoid)
		for _, c := range [4]Rect{
			RectAt(m.Left, m.Top, size.W, size.H),
			RectAt(m.Right-size.W, m.Top, size.W, size.H),
			RectAt(m.Left, m.Bottom-size.H, size.W, size.H),
			RectAt(m.Right-size.W, m.Bottom-size.H, size.W, size.H),
		} {
			if !fits(c) {
				continue
			}
			d := dist2(c.Center(), target)
			if !found || (clear && !bestClear) || (clear == bestClear && d > bestDist) {
				best, bestClear, bestDist, found = c, clear, d, true
			}
		}
	}
	if found {
		return best, false
	}
	v := Bounds(monitors)
	return RectAt(v.Right, v.Top, size.W, size.H), true
}
