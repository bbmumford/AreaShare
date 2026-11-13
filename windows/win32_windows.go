package main

import (
	"unsafe"

	"golang.org/x/sys/windows"

	"areashare/internal/geom"
)

// The bindings below cover exactly the Win32 surface the frame, the mirror
// and the capture loop use. Handles are plain uintptr values; rectangles are
// geom.Rect, whose layout matches RECT.

var (
	user32   = windows.NewLazySystemDLL("user32.dll")
	gdi32    = windows.NewLazySystemDLL("gdi32.dll")
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")
	dwmapi   = windows.NewLazySystemDLL("dwmapi.dll")
	shell32  = windows.NewLazySystemDLL("shell32.dll")

	procRegisterClassExW              = user32.NewProc("RegisterClassExW")
	procCreateWindowExW               = user32.NewProc("CreateWindowExW")
	procDefWindowProcW                = user32.NewProc("DefWindowProcW")
	procDestroyWindow                 = user32.NewProc("DestroyWindow")
	procShowWindow                    = user32.NewProc("ShowWindow")
	procGetMessageW                   = user32.NewProc("GetMessageW")
	procTranslateMessage              = user32.NewProc("TranslateMessage")
	procDispatchMessageW              = user32.NewProc("DispatchMessageW")
	procPostMessageW                  = user32.NewProc("PostMessageW")
	procPostQuitMessage               = user32.NewProc("PostQuitMessage")
	procSetWindowPos                  = user32.NewProc("SetWindowPos")
	procSetWindowRgn                  = user32.NewProc("SetWindowRgn")
	procInvalidateRect                = user32.NewProc("InvalidateRect")
	procBeginPaint                    = user32.NewProc("BeginPaint")
	procEndPaint                      = user32.NewProc("EndPaint")
	procFillRect                      = user32.NewProc("FillRect")
	procDrawTextW                     = user32.NewProc("DrawTextW")
	procGetDC                         = user32.NewProc("GetDC")
	procReleaseDC                     = user32.NewProc("ReleaseDC")
	procGetCursorPos                  = user32.NewProc("GetCursorPos")
	procGetCursorInfo                 = user32.NewProc("GetCursorInfo")
	procGetIconInfo                   = user32.NewProc("GetIconInfo")
	procDrawIconEx                    = user32.NewProc("DrawIconEx")
	procLoadCursorW                   = user32.NewProc("LoadCursorW")
	procLoadIconW                     = user32.NewProc("LoadIconW")
	procSetCursor                     = user32.NewProc("SetCursor")
	procSetCapture                    = user32.NewProc("SetCapture")
	procReleaseCapture                = user32.NewProc("ReleaseCapture")
	procEnumDisplayMonitors           = user32.NewProc("EnumDisplayMonitors")
	procGetMonitorInfoW               = user32.NewProc("GetMonitorInfoW")
	procGetDpiForWindow               = user32.NewProc("GetDpiForWindow")
	procSetProcessDpiAwarenessContext = user32.NewProc("SetProcessDpiAwarenessContext")
	procSetProcessDPIAware            = user32.NewProc("SetProcessDPIAware")
	procSetWindowDisplayAffinity      = user32.NewProc("SetWindowDisplayAffinity")
	procCreatePopupMenu               = user32.NewProc("CreatePopupMenu")
	procAppendMenuW                   = user32.NewProc("AppendMenuW")
	procTrackPopupMenu                = user32.NewProc("TrackPopupMenu")
	procDestroyMenu                   = user32.NewProc("DestroyMenu")
	procSetForegroundWindow           = user32.NewProc("SetForegroundWindow")
	procCreateIconIndirect            = user32.NewProc("CreateIconIndirect")

	procCreateRectRgn          = gdi32.NewProc("CreateRectRgn")
	procCombineRgn             = gdi32.NewProc("CombineRgn")
	procDeleteObject           = gdi32.NewProc("DeleteObject")
	procCreateSolidBrush       = gdi32.NewProc("CreateSolidBrush")
	procCreateCompatibleDC     = gdi32.NewProc("CreateCompatibleDC")
	procCreateCompatibleBitmap = gdi32.NewProc("CreateCompatibleBitmap")
	procCreateBitmap           = gdi32.NewProc("CreateBitmap")
	procCreateDIBSection       = gdi32.NewProc("CreateDIBSection")
	procSelectObject           = gdi32.NewProc("SelectObject")
	procDeleteDC               = gdi32.NewProc("DeleteDC")
	procBitBlt                 = gdi32.NewProc("BitBlt")
	procPatBlt                 = gdi32.NewProc("PatBlt")
	procSetBkMode              = gdi32.NewProc("SetBkMode")
	procSetTextColor           = gdi32.NewProc("SetTextColor")
	procCreateFontW            = gdi32.NewProc("CreateFontW")
	procGetDeviceCaps          = gdi32.NewProc("GetDeviceCaps")

	procGetModuleHandleW = kernel32.NewProc("GetModuleHandleW")

	procDwmSetWindowAttribute = dwmapi.NewProc("DwmSetWindowAttribute")

	procShellExecuteW = shell32.NewProc("ShellExecuteW")
)

const (
	wmNull              = 0x0000
	wmDestroy           = 0x0002
	wmPaint             = 0x000F
	wmClose             = 0x0010
	wmEraseBkgnd        = 0x0014
	wmSetCursor         = 0x0020
	wmMouseActivate     = 0x0021
	wmWindowPosChanging = 0x0046
	wmDisplayChange     = 0x007E
	wmSysCommand        = 0x0112
	wmMouseMove         = 0x0200
	wmLButtonDown       = 0x0201
	wmLButtonUp         = 0x0202
	wmRButtonUp         = 0x0205
	wmCaptureChanged    = 0x0215
	wmDpiChanged        = 0x02E0
	wmApp               = 0x8000

	wsPopup        = 0x80000000
	wsSysMenu      = 0x00080000
	wsExTopmost    = 0x00000008
	wsExToolWindow = 0x00000080
	wsExAppWindow  = 0x00040000
	wsExNoActivate = 0x08000000

	swpNoSize     = 0x0001
	swpNoMove     = 0x0002
	swpNoZOrder   = 0x0004
	swpNoActivate = 0x0010

	swShowNoActivate = 4

	hwndBottom  = uintptr(1)
	hwndTopmost = ^uintptr(0)

	scMinimize = 0xF020

	maNoActivate = 3

	ropSrcCopy    = 0x00CC0020
	ropCaptureBlt = 0x40000000
	ropBlackness  = 0x00000042

	rgnOr   = 2
	rgnDiff = 4

	idcArrow    = 32512
	idcSizeNWSE = 32642
	idcSizeNESW = 32643
	idcSizeWE   = 32644
	idcSizeNS   = 32645
	idcSizeAll  = 32646

	idiApplication = 32512

	dtVCenter     = 0x0004
	dtSingleLine  = 0x0020
	dtNoPrefix    = 0x0800
	dtEndEllipsis = 0x8000

	bkTransparent = 1

	mfString    = 0x0000
	mfGrayed    = 0x0001
	mfChecked   = 0x0008
	mfPopup     = 0x0010
	mfSeparator = 0x0800

	tpmRightButton = 0x0002
	tpmNoNotify    = 0x0080
	tpmReturnCmd   = 0x0100

	wdaExcludeFromCapture = 0x11

	dwmwaWindowCornerPreference = 33
	dwmwcpDoNotRound            = 1

	diNormal      = 0x0003
	cursorShowing = 0x0001

	logPixelsX = 88

	monitorInfoPrimary = 0x0001

	mbIconError       = 0x0010
	mbIconWarning     = 0x0030
	mbIconInformation = 0x0040
)

type wndClassEx struct {
	size       uint32
	style      uint32
	wndProc    uintptr
	clsExtra   int32
	wndExtra   int32
	instance   uintptr
	icon       uintptr
	cursor     uintptr
	background uintptr
	menuName   *uint16
	className  *uint16
	iconSm     uintptr
}

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      geom.Point
}

type paintStruct struct {
	hdc       uintptr
	erase     int32
	paint     geom.Rect
	restore   int32
	incUpdate int32
	reserved  [32]byte
}

type monitorInfo struct {
	size    uint32
	monitor geom.Rect
	work    geom.Rect
	flags   uint32
}

type windowPos struct {
	hwnd         uintptr
	insertAfter  uintptr
	x, y, cx, cy int32
	flags        uint32
}

type cursorInfo struct {
	size   uint32
	flags  uint32
	cursor uintptr
	pos    geom.Point
}

type iconInfo struct {
	isIcon   int32
	xHotspot uint32
	yHotspot uint32
	mask     uintptr
	color    uintptr
}

type bitmapInfoHeader struct {
	size          uint32
	width         int32
	height        int32
	planes        uint16
	bitCount      uint16
	compression   uint32
	sizeImage     uint32
	xPelsPerMeter int32
	yPelsPerMeter int32
	clrUsed       uint32
	clrImportant  uint32
}

// rgb builds a COLORREF, which stores the channels as 0x00BBGGRR.
func rgb(r, g, b uint32) uintptr { return uintptr(r | g<<8 | b<<16) }

func utf16(s string) *uint16 {
	p, err := windows.UTF16PtrFromString(s)
	if err != nil {
		// Only a string with an embedded NUL fails; none of ours has one.
		p, _ = windows.UTF16PtrFromString("")
	}
	return p
}

// available reports whether an optional API exists on this Windows version.
func available(p *windows.LazyProc) bool { return p.Find() == nil }

func moduleHandle() uintptr {
	h, _, _ := procGetModuleHandleW.Call(0)
	return h
}

func registerClass(wc *wndClassEx) error {
	wc.size = uint32(unsafe.Sizeof(*wc))
	if atom, _, err := procRegisterClassExW.Call(uintptr(unsafe.Pointer(wc))); atom == 0 {
		return err
	}
	return nil
}

func createWindow(exStyle, style uint32, class, title *uint16, r geom.Rect, instance uintptr) (uintptr, error) {
	hwnd, _, err := procCreateWindowExW.Call(
		uintptr(exStyle), uintptr(unsafe.Pointer(class)), uintptr(unsafe.Pointer(title)), uintptr(style),
		uintptr(r.Left), uintptr(r.Top), uintptr(r.W()), uintptr(r.H()),
		0, 0, instance, 0,
	)
	if hwnd == 0 {
		return 0, err
	}
	return hwnd, nil
}

func defWindowProc(hwnd, message, wParam, lParam uintptr) uintptr {
	r, _, _ := procDefWindowProcW.Call(hwnd, message, wParam, lParam)
	return r
}

func destroyWindow(hwnd uintptr) { procDestroyWindow.Call(hwnd) }

func showWindow(hwnd uintptr, cmd int32) { procShowWindow.Call(hwnd, uintptr(cmd)) }

func postMessage(hwnd, message, wParam, lParam uintptr) bool {
	r, _, _ := procPostMessageW.Call(hwnd, message, wParam, lParam)
	return r != 0
}

func postQuitMessage(code int32) { procPostQuitMessage.Call(uintptr(code)) }

func setWindowPos(hwnd, insertAfter uintptr, r geom.Rect, flags uint32) {
	procSetWindowPos.Call(hwnd, insertAfter,
		uintptr(r.Left), uintptr(r.Top), uintptr(r.W()), uintptr(r.H()), uintptr(flags))
}

// setWindowRgn hands rgn to the system, which owns it from then on.
func setWindowRgn(hwnd, rgn uintptr) { procSetWindowRgn.Call(hwnd, rgn, 1) }

func invalidate(hwnd uintptr) { procInvalidateRect.Call(hwnd, 0, 0) }

func beginPaint(hwnd uintptr, ps *paintStruct) uintptr {
	hdc, _, _ := procBeginPaint.Call(hwnd, uintptr(unsafe.Pointer(ps)))
	return hdc
}

func endPaint(hwnd uintptr, ps *paintStruct) {
	procEndPaint.Call(hwnd, uintptr(unsafe.Pointer(ps)))
}

func fillRect(hdc uintptr, r geom.Rect, brush uintptr) {
	procFillRect.Call(hdc, uintptr(unsafe.Pointer(&r)), brush)
}

func drawText(hdc uintptr, text string, r geom.Rect, format uint32) {
	s, err := windows.UTF16FromString(text)
	if err != nil {
		return
	}
	procDrawTextW.Call(hdc, uintptr(unsafe.Pointer(&s[0])), uintptr(len(s)-1),
		uintptr(unsafe.Pointer(&r)), uintptr(format))
}

func getDC(hwnd uintptr) uintptr {
	hdc, _, _ := procGetDC.Call(hwnd)
	return hdc
}

func releaseDC(hwnd, hdc uintptr) { procReleaseDC.Call(hwnd, hdc) }

func cursorPos() geom.Point {
	var p geom.Point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&p)))
	return p
}

func loadCursor(id uintptr) uintptr {
	h, _, _ := procLoadCursorW.Call(0, id)
	return h
}

func setCursor(h uintptr) { procSetCursor.Call(h) }

func setCapture(hwnd uintptr) { procSetCapture.Call(hwnd) }

func releaseCapture() { procReleaseCapture.Call() }

func deleteObject(h uintptr) {
	if h != 0 {
		procDeleteObject.Call(h)
	}
}

func selectObject(hdc, obj uintptr) uintptr {
	old, _, _ := procSelectObject.Call(hdc, obj)
	return old
}

func createSolidBrush(color uintptr) uintptr {
	h, _, _ := procCreateSolidBrush.Call(color)
	return h
}

func createRectRgn(r geom.Rect) uintptr {
	h, _, _ := procCreateRectRgn.Call(uintptr(r.Left), uintptr(r.Top), uintptr(r.Right), uintptr(r.Bottom))
	return h
}

func combineRgn(dst, a, b uintptr, mode int32) {
	procCombineRgn.Call(dst, a, b, uintptr(mode))
}

func bitBlt(dst uintptr, x, y, w, h int32, src uintptr, sx, sy int32, rop uint32) bool {
	r, _, _ := procBitBlt.Call(dst, uintptr(x), uintptr(y), uintptr(w), uintptr(h),
		src, uintptr(sx), uintptr(sy), uintptr(rop))
	return r != 0
}

// createFont returns a semi-bold Segoe UI face of the given pixel height.
func createFont(pixelHeight int32) uintptr {
	const (
		weightSemiBold   = 600
		defaultCharset   = 1
		clearTypeQuality = 5
	)
	h, _, _ := procCreateFontW.Call(
		uintptr(-pixelHeight), 0, 0, 0, weightSemiBold, 0, 0, 0,
		defaultCharset, 0, 0, clearTypeQuality, 0,
		uintptr(unsafe.Pointer(utf16("Segoe UI"))),
	)
	return h
}

// dpiForWindow returns the DPI of the monitor a window is on, falling back to
// the system DPI where per-window DPI is not available.
func dpiForWindow(hwnd uintptr) int32 {
	if available(procGetDpiForWindow) {
		if dpi, _, _ := procGetDpiForWindow.Call(hwnd); dpi != 0 {
			return int32(dpi)
		}
	}
	hdc := getDC(0)
	if hdc == 0 {
		return 96
	}
	defer releaseDC(0, hdc)
	dpi, _, _ := procGetDeviceCaps.Call(hdc, logPixelsX)
	if dpi == 0 {
		return 96
	}
	return int32(dpi)
}

// enableDPIAwareness makes every coordinate the process sees a physical
// pixel, which the capture needs: a scaled coordinate space would copy the
// wrong part of the screen on any display not at 100%.
func enableDPIAwareness() {
	const perMonitorAwareV2 = ^uintptr(3) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is -4
	if available(procSetProcessDpiAwarenessContext) {
		if ok, _, _ := procSetProcessDpiAwarenessContext.Call(perMonitorAwareV2); ok != 0 {
			return
		}
	}
	if available(procSetProcessDPIAware) {
		procSetProcessDPIAware.Call()
	}
}

// excludeFromCapture hides a window from every screen capture, ours
// included. Windows before 10 version 2004 reject the request; the frame is
// then simply captured like any other window.
func excludeFromCapture(hwnd uintptr) {
	if available(procSetWindowDisplayAffinity) {
		procSetWindowDisplayAffinity.Call(hwnd, wdaExcludeFromCapture)
	}
}

// squareCorners stops Windows 11 rounding a window's corners, which would
// clip the corner pixels of the shared picture.
func squareCorners(hwnd uintptr) {
	if !available(procDwmSetWindowAttribute) {
		return
	}
	pref := uint32(dwmwcpDoNotRound)
	procDwmSetWindowAttribute.Call(hwnd, dwmwaWindowCornerPreference,
		uintptr(unsafe.Pointer(&pref)), unsafe.Sizeof(pref))
}

// monitorScratch collects rectangles while EnumDisplayMonitors runs; it is
// only touched on the UI thread.
var monitorScratch struct {
	primary []geom.Rect
	others  []geom.Rect
}

var monitorEnumCallback = windows.NewCallback(func(monitor, hdc, rect, lParam uintptr) uintptr {
	mi := monitorInfo{size: uint32(unsafe.Sizeof(monitorInfo{}))}
	if ok, _, _ := procGetMonitorInfoW.Call(monitor, uintptr(unsafe.Pointer(&mi))); ok != 0 && !mi.monitor.Empty() {
		if mi.flags&monitorInfoPrimary != 0 {
			monitorScratch.primary = append(monitorScratch.primary, mi.monitor)
		} else {
			monitorScratch.others = append(monitorScratch.others, mi.monitor)
		}
	}
	return 1
})

// monitors returns every display's rectangle in physical pixels, the primary
// display first.
func monitors() []geom.Rect {
	monitorScratch.primary, monitorScratch.others = nil, nil
	procEnumDisplayMonitors.Call(0, 0, monitorEnumCallback, 0)
	return append(monitorScratch.primary, monitorScratch.others...)
}

func messageBox(owner uintptr, text string, flags uint32) {
	windows.MessageBox(windows.HWND(owner), utf16(text), utf16(appName), flags)
}

// messageLoop dispatches messages until WM_QUIT.
func messageLoop() {
	var m msg
	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			return
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
}
