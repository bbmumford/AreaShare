package geom

import "testing"

var (
	testMetrics = MetricsForDPI(96)
	// A 57-inch super-ultrawide beside a laptop panel.
	wide   = RectAt(0, 0, 7680, 2160)
	laptop = RectAt(7680, 540, 1920, 1080)
)

func TestMetricsScaleWithDPI(t *testing.T) {
	at100, at150 := MetricsForDPI(96), MetricsForDPI(144)
	if at100.Border != 6 || at150.Border != 9 {
		t.Fatalf("border = %d at 96 DPI and %d at 144 DPI, want 6 and 9", at100.Border, at150.Border)
	}
	if got := MetricsForDPI(0); got != at100 {
		t.Fatalf("an unknown DPI gave %+v, want the 96 DPI metrics %+v", got, at100)
	}
}

func TestFitInto(t *testing.T) {
	bounds := RectAt(0, 0, 1000, 800)
	cases := []struct {
		name     string
		in, want Rect
	}{
		{"already inside", RectAt(10, 20, 100, 100), RectAt(10, 20, 100, 100)},
		{"off the left and top", RectAt(-50, -70, 100, 100), RectAt(0, 0, 100, 100)},
		{"off the right and bottom", RectAt(950, 790, 100, 100), RectAt(900, 700, 100, 100)},
		{"larger than bounds", RectAt(-10, -10, 3000, 3000), bounds},
	}
	for _, c := range cases {
		if got := c.in.FitInto(bounds); got != c.want {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
}

func TestBestMonitor(t *testing.T) {
	screens := []Rect{wide, laptop}
	if got, _ := BestMonitor(RectAt(7000, 600, 1000, 500), screens); got != wide {
		t.Errorf("a region mostly on the wide display chose %+v", got)
	}
	if got, _ := BestMonitor(RectAt(7500, 600, 1000, 500), screens); got != laptop {
		t.Errorf("a region mostly on the laptop chose %+v", got)
	}
	if got, _ := BestMonitor(RectAt(20000, 0, 100, 100), screens); got != laptop {
		t.Errorf("an off-screen region chose %+v, want the nearest display", got)
	}
	if _, ok := BestMonitor(wide, nil); ok {
		t.Error("no displays still reported a monitor")
	}
}

func TestComputeTabPlacement(t *testing.T) {
	m := testMetrics
	cases := []struct {
		name   string
		region Rect
		want   TabSide
	}{
		{"room above", RectAt(1000, 500, 1920, 1080), TabAbove},
		{"against the top", RectAt(1000, 0, 1920, 1080), TabBelow},
		{"full height", RectAt(1000, 0, 1920, 2160), TabInside},
	}
	for _, c := range cases {
		l := Compute(c.region, wide, m)
		if l.Side != c.want {
			t.Errorf("%s: tab side %d, want %d", c.name, l.Side, c.want)
			continue
		}
		if l.Outer != c.region.Inflate(m.Border) {
			t.Errorf("%s: outer %+v is not the region grown by the border", c.name, l.Outer)
		}
		if !l.Window.ContainsRect(l.Outer) || !l.Window.ContainsRect(l.Tab) {
			t.Errorf("%s: window %+v does not cover the ring and the tab", c.name, l.Window)
		}
		if l.Side != TabInside && l.Tab.Intersects(c.region) {
			t.Errorf("%s: tab %+v overlaps the shared region", c.name, l.Tab)
		}
		if l.Side == TabInside && !c.region.ContainsRect(l.Tab) {
			t.Errorf("%s: inside tab %+v leaves the region", c.name, l.Tab)
		}
	}
}

func TestComputeNarrowRegionNarrowsTab(t *testing.T) {
	m := testMetrics
	region := RectAt(500, 500, 100, 400)
	l := Compute(region, wide, m)
	if l.Tab.W() != l.Outer.W() {
		t.Fatalf("tab width %d, want the ring width %d", l.Tab.W(), l.Outer.W())
	}
}

func TestHit(t *testing.T) {
	m := testMetrics
	region := RectAt(1000, 500, 1920, 1080)
	l := Compute(region, wide, m)
	mid := region.Center()
	cases := []struct {
		name string
		p    Point
		want Zone
	}{
		{"inside the region", mid, ZoneNone},
		{"outside the frame", Point{10, 10}, ZoneNone},
		{"on the tab", l.Tab.Center(), ZoneMove},
		{"left edge", Point{region.Left - 1, mid.Y}, ZoneLeft},
		{"right edge", Point{region.Right, mid.Y}, ZoneRight},
		{"top edge", Point{mid.X, region.Top - 1}, ZoneTop},
		{"bottom edge", Point{mid.X, region.Bottom}, ZoneBottom},
		{"top-left corner", Point{l.Outer.Left, l.Outer.Top}, ZoneTopLeft},
		{"top-right, along the top", Point{region.Right - 2, region.Top - 1}, ZoneTopRight},
		{"bottom-left, along the side", Point{region.Left - 1, region.Bottom - 2}, ZoneBottomLeft},
		{"bottom-right corner", Point{l.Outer.Right - 1, l.Outer.Bottom - 1}, ZoneBottomRight},
	}
	for _, c := range cases {
		if got := l.Hit(c.p, m); got != c.want {
			t.Errorf("%s: zone %d, want %d", c.name, got, c.want)
		}
	}
}

func TestHitInsideTabMoves(t *testing.T) {
	m := testMetrics
	l := Compute(RectAt(1000, 0, 1920, 2160), wide, m)
	if got := l.Hit(l.Tab.Center(), m); got != ZoneMove {
		t.Fatalf("the inside tab gave zone %d, want move", got)
	}
}

func TestDragMoveStaysOnScreen(t *testing.T) {
	m := testMetrics
	start := RectAt(1000, 500, 1920, 1080)
	d := Drag{Zone: ZoneMove, Start: start, Anchor: Point{1100, 480}}
	if got := d.Apply(Point{1150, 500}, wide, m); got != start.Offset(50, 20) {
		t.Errorf("a small move gave %+v", got)
	}
	got := d.Apply(Point{-9000, 9000}, wide, m)
	if want := RectAt(0, 2160-1080, 1920, 1080); got != want {
		t.Errorf("a move past the corner gave %+v, want %+v", got, want)
	}
}

func TestDragResize(t *testing.T) {
	m := testMetrics
	start := RectAt(1000, 500, 1920, 1080)
	anchor := Point{start.Right, start.Bottom}

	d := Drag{Zone: ZoneBottomRight, Start: start, Anchor: anchor}
	if got, want := d.Apply(Point{anchor.X + 80, anchor.Y + 40}, wide, m), RectAt(1000, 500, 2000, 1120); got != want {
		t.Errorf("growing from the corner gave %+v, want %+v", got, want)
	}
	if got := d.Apply(Point{-5000, -5000}, wide, m); got.W() != m.MinW || got.H() != m.MinH || got.Origin() != start.Origin() {
		t.Errorf("shrinking past the minimum gave %+v", got)
	}
	if got := d.Apply(Point{90000, 90000}, wide, m); got.Right != wide.Right || got.Bottom != wide.Bottom {
		t.Errorf("growing past the screen gave %+v", got)
	}

	left := Drag{Zone: ZoneLeft, Start: start, Anchor: Point{start.Left, 900}}
	got := left.Apply(Point{start.Left - 100, 1300}, wide, m)
	if want := (Rect{900, 500, start.Right, start.Bottom}); got != want {
		t.Errorf("dragging the left edge gave %+v, want %+v", got, want)
	}
	if got := left.Apply(Point{90000, 0}, wide, m); got.Right != start.Right || got.W() != m.MinW {
		t.Errorf("pushing the left edge through the right gave %+v", got)
	}
}

func TestResizedKeepsCentre(t *testing.T) {
	region := RectAt(1000, 500, 1920, 1080)
	got := Resized(region, Size{1280, 720}, wide)
	if got.Size() != (Size{1280, 720}) || got.Center() != region.Center() {
		t.Errorf("resizing about the centre gave %+v", got)
	}
	corner := Resized(RectAt(0, 0, 200, 200), Size{1280, 720}, wide)
	if corner != RectAt(0, 0, 1280, 720) {
		t.Errorf("resizing in the corner gave %+v, want it pushed back on screen", corner)
	}
}

func TestPlaceMirrorNeverOverlapsTheFrame(t *testing.T) {
	size := Size{1920, 1080}
	screens := []Rect{wide, laptop}
	for x := int32(0); x+size.W <= wide.Right; x += 480 {
		for y := int32(0); y+size.H <= wide.Bottom; y += 270 {
			avoid := Compute(RectAt(x, y, size.W, size.H), wide, testMetrics).Window
			pos, parked := PlaceMirror(Rect{}, size, avoid, screens)
			if parked {
				t.Fatalf("region at %d,%d: the mirror was parked although there is room", x, y)
			}
			if pos.Intersects(avoid) {
				t.Fatalf("region at %d,%d: mirror %+v overlaps the frame %+v", x, y, pos, avoid)
			}
			if pos.Size() != size {
				t.Fatalf("region at %d,%d: mirror size %+v", x, y, pos.Size())
			}
		}
	}
}

func TestPlaceMirrorPrefersAnotherDisplay(t *testing.T) {
	size := Size{1920, 1080}
	avoid := RectAt(3000, 500, 1920, 1080).Inflate(40)
	pos, _ := PlaceMirror(Rect{}, size, avoid, []Rect{wide, laptop})
	if !laptop.ContainsRect(pos) {
		t.Fatalf("mirror %+v is not on the display the region leaves free", pos)
	}
}

func TestPlaceMirrorIsStable(t *testing.T) {
	size := Size{1280, 720}
	screens := []Rect{wide}
	first, _ := PlaceMirror(Rect{}, size, RectAt(100, 100, 1280, 720), screens)
	// A small move of the region must not make the mirror jump.
	second, _ := PlaceMirror(first, size, RectAt(160, 140, 1280, 720), screens)
	if second != first {
		t.Fatalf("mirror moved from %+v to %+v although it was still clear", first, second)
	}
	// Moving the region onto the mirror must move the mirror off it.
	third, _ := PlaceMirror(first, size, first.Inflate(10), screens)
	if third.Intersects(first.Inflate(10)) {
		t.Fatalf("mirror %+v stayed under the region", third)
	}
}

func TestPlaceMirrorParksWhenNothingFits(t *testing.T) {
	small := RectAt(0, 0, 1920, 1080)
	size := Size{1600, 900}
	avoid := RectAt(160, 90, 1600, 900)
	pos, parked := PlaceMirror(Rect{}, size, avoid, []Rect{small})
	if !parked {
		t.Fatalf("mirror placed at %+v although every spot overlaps the region", pos)
	}
	if pos.Intersects(small) || pos.Size() != size {
		t.Fatalf("parked mirror %+v is on screen or the wrong size", pos)
	}
	// Once the region shrinks, the mirror comes back on screen.
	back, parked := PlaceMirror(pos, Size{640, 360}, RectAt(0, 0, 640, 360), []Rect{small})
	if parked || !small.ContainsRect(back) {
		t.Fatalf("mirror stayed parked at %+v after room appeared", back)
	}
}
