package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"

	"areashare/internal/version"
)

// buildVersion is the release this program was built as. The release build sets
// it with -ldflags "-X main.buildVersion=1.4.2"; any other build is "dev".
var buildVersion = "dev"

const (
	latestReleaseURL = "https://api.github.com/repos/bbmumford/AreaShare/releases/latest"
	releasesPageURL  = "https://github.com/bbmumford/AreaShare/releases/latest"

	// wmUpdateChecked tells the UI thread that updateCheck has a result.
	wmUpdateChecked = wmApp + 2

	mbYesNo = 0x0004
	idYes   = 6
)

// updateCheck carries the result of a check from the goroutine that asked
// the server to the UI thread that shows it.
var updateCheck struct {
	sync.Mutex
	running bool
	latest  string
	err     error
}

// checkForUpdates asks GitHub for the newest release without blocking the
// UI; the answer arrives as wmUpdateChecked.
func (a *app) checkForUpdates() {
	updateCheck.Lock()
	if updateCheck.running {
		updateCheck.Unlock()
		return
	}
	updateCheck.running = true
	updateCheck.Unlock()

	go func() {
		latest, err := latestRelease()
		updateCheck.Lock()
		updateCheck.running, updateCheck.latest, updateCheck.err = false, latest, err
		updateCheck.Unlock()
		postMessage(a.mirror, wmUpdateChecked, 0, 0)
	}()
}

func latestRelease() (string, error) {
	client := http.Client{Timeout: 20 * time.Second}
	request, err := http.NewRequest(http.MethodGet, latestReleaseURL, nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	response, err := client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("the update server answered %s", response.Status)
	}
	var release struct {
		Tag string `json:"tag_name"`
	}
	if err := json.NewDecoder(response.Body).Decode(&release); err != nil {
		return "", err
	}
	return release.Tag, nil
}

// showUpdateResult tells the user what the check found and, for a newer
// version, offers to open its download page. The program does not replace
// itself: the user downloads the new executable.
func (a *app) showUpdateResult() {
	updateCheck.Lock()
	latest, err := updateCheck.latest, updateCheck.err
	updateCheck.Unlock()

	switch {
	case err != nil:
		messageBox(0, fmt.Sprintf("Could not check for updates.\n\n%v", err), mbIconWarning)
	case version.Newer(latest, buildVersion):
		text := fmt.Sprintf("%s %s is available. You have %s.\n\nOpen the download page?", appName, latest, buildVersion)
		if answer, _ := windows.MessageBox(0, utf16(text), utf16(appName), mbYesNo|mbIconInformation); answer == idYes {
			openURL(releasesPageURL)
		}
	case buildVersion == "dev":
		messageBox(0, fmt.Sprintf("This is a development build. The newest release is %s.", latest), mbIconInformation)
	default:
		messageBox(0, fmt.Sprintf("%s %s is the newest version.", appName, buildVersion), mbIconInformation)
	}
}

func openURL(url string) {
	const swShowNormal = 1
	procShellExecuteW.Call(0, uintptr(unsafe.Pointer(utf16("open"))), uintptr(unsafe.Pointer(utf16(url))), 0, 0, swShowNormal)
}
