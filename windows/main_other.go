//go:build !windows

package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "AreaShare runs on Windows only. Build it with GOOS=windows; see ReadMe.md.")
	os.Exit(1)
}
