// AreaShare shares one rectangle of a large desktop through any conferencing
// app that can share a window. See ReadMe.md.
package main

import (
	"runtime"

	"golang.org/x/sys/windows"
)

func init() {
	// Windows delivers a window's messages to the thread that created it,
	// so the goroutine running main must stay on one thread.
	runtime.LockOSThread()
}

func main() {
	// The handle is held until the process exits; a second copy would put a
	// second frame and a second window named AreaShare on screen.
	_, err := windows.CreateMutex(nil, false, utf16(`Local\AreaShare.SingleInstance`))
	if err == windows.ERROR_ALREADY_EXISTS {
		messageBox(0, appName+" is already running. Right-click its red frame for options.", mbIconInformation)
		return
	}

	if err := run(); err != nil {
		messageBox(0, appName+" could not start.\n\n"+err.Error(), mbIconError)
		windows.Exit(1)
	}
}
