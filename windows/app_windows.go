package main

import (
	"errors"
	"fmt"
	"sync/atomic"
	"time"

	"golang.org/x/sys/windows"

	"areashare/internal/config"
	"areashare/internal/geom"
)

const (
	appName = "AreaShare"

	frameClassName  = "AreaShare.Frame"
	mirrorClassName = "AreaShare.Mirror"

	// wmTick asks the mirror window to refresh its copy of the region.
	wmTick = wmApp + 1
)

var (
	colorLive   = rgb(220, 38, 38)
	colorPaused = rgb(217, 119, 6)
	colorLabel  = rgb(255, 255, 255)
)

// app is the whole program's state. Two windows share it:
//
//   - the frame, a topmost ring around the region with a grab tab, which is
//     how the region is moved and resized and is never part of the picture;
//   - the mirror, an ordinary window the same size as the region that shows a
//     live copy of it. The mirror is the window to pick in a conferencing
//     app's "share a window" list.
//
// Everything except the ticker goroutine runs on the UI thread.
type app struct {
	instance uintptr
	frame    uintptr
	mirror   uintptr

	region     geom.Rect // the shared pixels, in screen coordinates
	metrics    geom.Metrics
	layout     geom.Layout
	mirrorRect geom.Rect   // where the mirror window currently is
	screens    []geom.Rect // every display, primary first
	drag       *geom.Drag  // non-nil while the pointer holds the frame
	paused     bool

	// applying and reapply let a DPI change that arrives while the frame is
	// being repositioned restart the layout instead of nesting inside it.
	applying bool
	reapply  bool

	shot capture

	cfg        config.Config
	cfgPath    string
	saveFailed bool // a save error has already been reported

	font        uintptr
	brushLive   uintptr
	brushPaused uintptr

	fps         atomic.Int32
	tickPending atomic.Bool
	closing     bool
}

// theApp is read by the window procedures, which the system calls without
// any context of ours.
var theApp *app

var (
	frameProcCallback  = windows.NewCallback(frameProc)
	mirrorProcCallback = windows.NewCallback(mirrorProc)
)

// run starts the program and returns when the user exits.
func run() error {
	enableDPIAwareness()

	a := &app{instance: moduleHandle()}
	theApp = a

	a.screens = monitors()
	if len(a.screens) == 0 {
		return errors.New("no displays were found")
	}

	var loadErr error
	if path, err := config.Path(); err == nil {
		a.cfgPath = path
		a.cfg, loadErr = config.Load(path)
	} else {
		a.cfg = config.Default()
	}
	a.fps.Store(int32(a.cfg.FPS))
	a.metrics = geom.MetricsForDPI(96)
	a.region = a.startRegion()

	a.brushLive = createSolidBrush(colorLive)
	a.brushPaused = createSolidBrush(colorPaused)

	icon := createAppIcon()
	if err := a.createWindows(icon); err != nil {
		return err
	}
	a.setMetrics(dpiForWindow(a.frame))
	a.applyRegion()

	showWindow(a.mirror, swShowNoActivate)
	showWindow(a.frame, swShowNoActivate)

	if loadErr != nil {
		messageBox(0, fmt.Sprintf("The saved settings could not be read, so the defaults are in use.\n\n%s\n%v", a.cfgPath, loadErr), mbIconWarning)
	}

	go a.tick()
	messageLoop()

	a.shot.close()
	deleteObject(a.font)
	deleteObject(a.brushLive)
	deleteObject(a.brushPaused)
	return nil
}

// startRegion returns the saved region if it still fits the displays, and
// otherwise a 16:9 region centred on the primary display.
func (a *app) startRegion() geom.Rect {
	bounds := geom.Bounds(a.screens)
	if r, ok := a.cfg.Region(); ok && r.Intersects(bounds) {
		r = r.FitInto(bounds)
		if r.W() >= a.metrics.MinW && r.H() >= a.metrics.MinH {
			return r
		}
	}
	primary := a.screens[0]
	for _, s := range []geom.Size{{W: 1920, H: 1080}, {W: 1280, H: 720}} {
		if primary.W() >= s.W+s.W/4 && primary.H() >= s.H+s.H/4 {
			return geom.CenterIn(primary, s)
		}
	}
	return geom.CenterIn(primary, geom.Size{W: primary.W() * 2 / 3, H: primary.H() * 2 / 3})
}

func (a *app) createWindows(icon uintptr) error {
	frameClass := utf16(frameClassName)
	if err := registerClass(&wndClassEx{
		wndProc:   frameProcCallback,
		instance:  a.instance,
		className: frameClass,
	}); err != nil {
		return fmt.Errorf("registering the frame window class: %w", err)
	}
	mirrorClass := utf16(mirrorClassName)
	if err := registerClass(&wndClassEx{
		wndProc:   mirrorProcCallback,
		instance:  a.instance,
		icon:      icon,
		iconSm:    icon,
		cursor:    loadCursor(idcArrow),
		className: mirrorClass,
	}); err != nil {
		return fmt.Errorf("registering the mirror window class: %w", err)
	}

	// The mirror has no caption or border: a window share includes the
	// whole window, so anything but the copied pixels would be shown to the
	// audience. It still appears on the taskbar and in window pickers.
	var err error
	a.mirror, err = createWindow(wsExAppWindow, wsPopup|wsSysMenu, mirrorClass, utf16(appName),
		geom.RectAt(a.region.Left, a.region.Top, a.region.W(), a.region.H()), a.instance)
	if err != nil {
		return fmt.Errorf("creating the mirror window: %w", err)
	}
	squareCorners(a.mirror)

	a.frame, err = createWindow(wsExTopmost|wsExToolWindow|wsExNoActivate, wsPopup, frameClass, utf16(appName+" frame"),
		a.region, a.instance)
	if err != nil {
		return fmt.Errorf("creating the frame window: %w", err)
	}
	squareCorners(a.frame)
	excludeFromCapture(a.frame)
	return nil
}

// setMetrics switches the frame to a display scale.
func (a *app) setMetrics(dpi int32) {
	a.metrics = geom.MetricsForDPI(dpi)
	deleteObject(a.font)
	a.font = createFont((13*dpi + 48) / 96)
}

// applyRegion makes both windows match a.region: the frame is laid out
// around it, the mirror takes its size and moves out of its way, and the
// copy is refreshed.
func (a *app) applyRegion() {
	if a.applying {
		a.reapply = true
		return
	}
	a.applying = true
	for pass := 0; pass < 3; pass++ {
		a.reapply = false
		a.applyOnce()
		if !a.reapply {
			break
		}
	}
	a.applying = false
}

func (a *app) applyOnce() {
	monitor, _ := geom.BestMonitor(a.region, a.screens)
	a.layout = geom.Compute(a.region, monitor, a.metrics)
	win := a.layout.Window

	setWindowPos(a.frame, hwndTopmost, win, swpNoActivate)
	local := func(r geom.Rect) geom.Rect { return r.Offset(-win.Left, -win.Top) }
	shape := createRectRgn(local(a.layout.Outer))
	hole := createRectRgn(local(a.layout.Region))
	tab := createRectRgn(local(a.layout.Tab))
	combineRgn(shape, shape, hole, rgnDiff)
	combineRgn(shape, shape, tab, rgnOr)
	deleteObject(hole)
	deleteObject(tab)
	setWindowRgn(a.frame, shape)
	invalidate(a.frame)

	if pos, _ := geom.PlaceMirror(a.mirrorRect, a.region.Size(), win, a.screens); pos != a.mirrorRect {
		a.mirrorRect = pos
		setWindowPos(a.mirror, hwndBottom, pos, swpNoActivate)
	}
	a.shot.resize(a.region.Size())
	a.refresh()
}

// refresh copies the region to the mirror now, unless sharing is paused, in
// which case the mirror keeps showing what it last had.
func (a *app) refresh() {
	if !a.paused {
		a.shot.grab(a.region, a.cfg.ShowCursor)
	}
	if hdc := getDC(a.mirror); hdc != 0 {
		a.shot.paint(hdc)
		releaseDC(a.mirror, hdc)
	}
}

// tick runs on its own goroutine and requests a refresh at the configured
// rate. It never queues a second request while one is outstanding, so a slow
// copy lowers the frame rate instead of flooding the message queue.
func (a *app) tick() {
	for {
		fps := a.fps.Load()
		if fps <= 0 {
			fps = config.DefaultFPS
		}
		time.Sleep(time.Second / time.Duration(fps))
		if a.tickPending.CompareAndSwap(false, true) {
			if !postMessage(a.mirror, wmTick, 0, 0) {
				a.tickPending.Store(false)
			}
		}
	}
}

// displaysChanged re-reads the monitors and pulls the region back on screen
// if its display went away.
func (a *app) displaysChanged() {
	screens := monitors()
	if len(screens) == 0 {
		return
	}
	a.screens = screens
	a.region = a.region.FitInto(geom.Bounds(screens))
	a.applyRegion()
	a.save()
}

// save persists the region and settings. The first failure is reported;
// later ones are not, so a read-only profile does not produce a message on
// every drag.
func (a *app) save() {
	if a.cfgPath == "" {
		return
	}
	a.cfg.SetRegion(a.region)
	a.cfg.FPS = int(a.fps.Load())
	err := config.Save(a.cfgPath, a.cfg)
	if err != nil && !a.saveFailed {
		a.saveFailed = true
		messageBox(0, fmt.Sprintf("The settings could not be saved.\n\n%s\n%v", a.cfgPath, err), mbIconWarning)
	}
}

func (a *app) setPaused(paused bool) {
	a.paused = paused
	invalidate(a.frame)
	a.refresh()
}

// quit closes both windows; destroying the mirror ends the message loop.
func (a *app) quit() {
	if a.closing {
		return
	}
	a.closing = true
	releaseCapture()
	destroyWindow(a.frame)
	destroyWindow(a.mirror)
}

// label is the text on the grab tab.
func (a *app) label() string {
	state := appName
	if a.paused {
		state = "Paused"
	}
	return fmt.Sprintf("%s   %d × %d", state, a.region.W(), a.region.H())
}

// frameProc is the frame window's procedure. The frame never takes focus;
// it reacts only to the pointer.
func frameProc(hwnd, message, wParam, lParam uintptr) uintptr {
	a := theApp
	if a == nil || hwnd != a.frame {
		return defWindowProc(hwnd, message, wParam, lParam)
	}
	switch message {
	case wmPaint:
		a.paintFrame()
		return 0

	case wmEraseBkgnd:
		return 1

	case wmMouseActivate:
		return maNoActivate

	case wmSetCursor:
		setCursor(loadCursor(zoneCursor(a.layout.Hit(cursorPos(), a.metrics))))
		return 1

	case wmLButtonDown:
		p := cursorPos()
		if zone := a.layout.Hit(p, a.metrics); zone != geom.ZoneNone {
			a.drag = &geom.Drag{Zone: zone, Start: a.region, Anchor: p}
			setCapture(hwnd)
		}
		return 0

	case wmMouseMove:
		if a.drag != nil {
			if r := a.drag.Apply(cursorPos(), geom.Bounds(a.screens), a.metrics); r != a.region {
				a.region = r
				a.applyRegion()
			}
		}
		return 0

	case wmLButtonUp:
		if a.drag != nil {
			releaseCapture()
		}
		return 0

	case wmCaptureChanged:
		if a.drag != nil {
			a.drag = nil
			a.save()
		}
		return 0

	case wmRButtonUp:
		if a.drag == nil {
			a.showMenu()
		}
		return 0

	case wmDpiChanged:
		a.setMetrics(int32(wParam & 0xFFFF))
		a.applyRegion()
		return 0

	case wmClose:
		a.quit()
		return 0
	}
	return defWindowProc(hwnd, message, wParam, lParam)
}

func (a *app) paintFrame() {
	var ps paintStruct
	hdc := beginPaint(a.frame, &ps)
	if hdc == 0 {
		return
	}
	defer endPaint(a.frame, &ps)

	brush := a.brushLive
	if a.paused {
		brush = a.brushPaused
	}
	win := a.layout.Window
	fillRect(hdc, geom.RectAt(0, 0, win.W(), win.H()), brush)

	text := a.layout.Tab.Offset(-win.Left, -win.Top)
	text.Left += a.metrics.Border + a.metrics.Border/2
	text.Right -= a.metrics.Border
	if text.Empty() {
		return
	}
	old := selectObject(hdc, a.font)
	procSetBkMode.Call(hdc, bkTransparent)
	procSetTextColor.Call(hdc, colorLabel)
	drawText(hdc, a.label(), text, dtSingleLine|dtVCenter|dtNoPrefix|dtEndEllipsis)
	selectObject(hdc, old)
}

func zoneCursor(z geom.Zone) uintptr {
	switch z {
	case geom.ZoneMove:
		return idcSizeAll
	case geom.ZoneLeft, geom.ZoneRight:
		return idcSizeWE
	case geom.ZoneTop, geom.ZoneBottom:
		return idcSizeNS
	case geom.ZoneTopLeft, geom.ZoneBottomRight:
		return idcSizeNWSE
	case geom.ZoneTopRight, geom.ZoneBottomLeft:
		return idcSizeNESW
	}
	return idcArrow
}

// mirrorProc is the mirror window's procedure. The mirror only paints the
// copy and keeps itself underneath every other window.
func mirrorProc(hwnd, message, wParam, lParam uintptr) uintptr {
	a := theApp
	if a == nil || hwnd != a.mirror {
		return defWindowProc(hwnd, message, wParam, lParam)
	}
	switch message {
	case wmTick:
		a.refresh()
		a.tickPending.Store(false)
		return 0

	case wmUpdateChecked:
		a.showUpdateResult()
		return 0

	case wmPaint:
		var ps paintStruct
		if hdc := beginPaint(hwnd, &ps); hdc != 0 {
			a.shot.paint(hdc)
			endPaint(hwnd, &ps)
		}
		return 0

	case wmEraseBkgnd:
		return 1

	case wmWindowPosChanging:
		// A conferencing app raises the window it starts sharing. Raised,
		// the mirror would cover the desktop it is copying, so every
		// z-order change is turned into "send to the bottom".
		pinToBottom(lParam)
		return 0

	case wmSysCommand:
		// A minimised window stops being captured, which would end the
		// share without any sign of it on screen.
		if wParam&0xFFF0 == scMinimize {
			return 0
		}

	case wmDisplayChange:
		a.displaysChanged()
		return 0

	case wmDpiChanged:
		// The mirror is a pixel-for-pixel copy; it must not be rescaled
		// when it lands on a display with a different scale.
		return 0

	case wmClose:
		a.quit()
		return 0

	case wmDestroy:
		postQuitMessage(0)
		return 0
	}
	return defWindowProc(hwnd, message, wParam, lParam)
}
