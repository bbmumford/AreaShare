package main

import (
	"fmt"
	"unsafe"

	"areashare/internal/config"
	"areashare/internal/geom"
)

// Menu command identifiers. Frame rates and sizes are offsets from their
// base into config.FrameRates and sizePresets.
const (
	cmdPause = iota + 1
	cmdCursor
	cmdCenter
	cmdUpdate
	cmdExit

	cmdFPSBase  = 100
	cmdSizeBase = 200
)

// sizePresets are the region sizes offered in the menu.
var sizePresets = []geom.Size{
	{W: 1280, H: 720},
	{W: 1600, H: 900},
	{W: 1920, H: 1080},
	{W: 2560, H: 1440},
	{W: 3840, H: 2160},
}

func appendItem(menu uintptr, flags uint32, id uintptr, text string) {
	procAppendMenuW.Call(menu, uintptr(flags), id, uintptr(unsafe.Pointer(utf16(text))))
}

func checkedIf(on bool) uint32 {
	if on {
		return mfChecked
	}
	return 0
}

// showMenu opens the frame's context menu at the pointer and carries out
// the chosen command.
func (a *app) showMenu() {
	menu, _, _ := procCreatePopupMenu.Call()
	sizes, _, _ := procCreatePopupMenu.Call()
	rates, _, _ := procCreatePopupMenu.Call()
	if menu == 0 || sizes == 0 || rates == 0 {
		procDestroyMenu.Call(menu)
		procDestroyMenu.Call(sizes)
		procDestroyMenu.Call(rates)
		return
	}
	// Destroying a menu destroys the submenus attached to it.
	defer procDestroyMenu.Call(menu)

	bounds := geom.Bounds(a.screens)
	for i, s := range sizePresets {
		flags := mfString | checkedIf(a.region.Size() == s)
		if s.W > bounds.W() || s.H > bounds.H() {
			flags |= mfGrayed
		}
		appendItem(sizes, flags, uintptr(cmdSizeBase+i), fmt.Sprintf("%d × %d", s.W, s.H))
	}
	for i, f := range config.FrameRates {
		appendItem(rates, mfString|checkedIf(int(a.fps.Load()) == f), uintptr(cmdFPSBase+i), fmt.Sprintf("%d frames per second", f))
	}

	pause := "Pause (freeze the shared picture)"
	if a.paused {
		pause = "Resume"
	}
	appendItem(menu, mfString, cmdPause, pause)
	appendItem(menu, mfSeparator, 0, "")
	appendItem(menu, mfPopup, sizes, "Size")
	appendItem(menu, mfPopup, rates, "Refresh rate")
	appendItem(menu, mfString|checkedIf(a.cfg.ShowCursor), cmdCursor, "Show the mouse pointer")
	appendItem(menu, mfString, cmdCenter, "Centre on this display")
	appendItem(menu, mfSeparator, 0, "")
	appendItem(menu, mfString, cmdUpdate, "Check for updates…")
	appendItem(menu, mfString, cmdExit, "Exit "+appName)

	// A popup menu only closes on an outside click if its owner is the
	// foreground window, and needs a message afterwards to finish closing.
	p := cursorPos()
	procSetForegroundWindow.Call(a.frame)
	cmd, _, _ := procTrackPopupMenu.Call(menu, tpmReturnCmd|tpmNoNotify|tpmRightButton,
		uintptr(p.X), uintptr(p.Y), 0, a.frame, 0)
	postMessage(a.frame, wmNull, 0, 0)

	a.runCommand(int(cmd))
}

func (a *app) runCommand(cmd int) {
	bounds := geom.Bounds(a.screens)
	switch {
	case cmd == cmdPause:
		a.setPaused(!a.paused)
		return

	case cmd == cmdCursor:
		a.cfg.ShowCursor = !a.cfg.ShowCursor
		a.refresh()

	case cmd == cmdCenter:
		if monitor, ok := geom.BestMonitor(a.region, a.screens); ok {
			a.region = geom.CenterIn(monitor, a.region.Size())
			a.applyRegion()
		}

	case cmd == cmdUpdate:
		a.checkForUpdates()
		return

	case cmd == cmdExit:
		a.quit()
		return

	case cmd >= cmdSizeBase && cmd < cmdSizeBase+len(sizePresets):
		a.region = geom.Resized(a.region, sizePresets[cmd-cmdSizeBase], bounds)
		a.applyRegion()

	case cmd >= cmdFPSBase && cmd < cmdFPSBase+len(config.FrameRates):
		a.fps.Store(int32(config.FrameRates[cmd-cmdFPSBase]))

	default:
		return
	}
	a.save()
}

// pinToBottom rewrites the WINDOWPOS a WM_WINDOWPOSCHANGING message carries
// so that the window ends up below all others whatever was requested.
func pinToBottom(lParam uintptr) {
	// lParam is the address of a structure the system owns for the length
	// of the message; reading the pointer out of the parameter's own
	// storage keeps the conversion within the unsafe rules.
	wp := *(**windowPos)(unsafe.Pointer(&lParam))
	if wp == nil {
		return
	}
	wp.insertAfter = hwndBottom
	wp.flags &^= swpNoZOrder
}
