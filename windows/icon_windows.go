package main

import "unsafe"

// createAppIcon draws the program's icon, a red frame around an empty
// centre, so the executable needs no embedded resources. It falls back to the
// stock application icon if any step fails.
func createAppIcon() uintptr {
	const (
		size   = 32
		margin = 3
		stroke = 4
	)
	stock, _, _ := procLoadIconW.Call(0, idiApplication)

	header := bitmapInfoHeader{
		size:     uint32(unsafe.Sizeof(bitmapInfoHeader{})),
		width:    size,
		height:   -size, // negative height: rows run top to bottom
		planes:   1,
		bitCount: 32,
	}
	var bits unsafe.Pointer
	color, _, _ := procCreateDIBSection.Call(0, uintptr(unsafe.Pointer(&header)), 0,
		uintptr(unsafe.Pointer(&bits)), 0, 0)
	if color == 0 || bits == nil {
		return stock
	}
	defer deleteObject(color)

	pixels := unsafe.Slice((*uint32)(bits), size*size)
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			inOuter := x >= margin && x < size-margin && y >= margin+2 && y < size-margin-2
			inInner := x >= margin+stroke && x < size-margin-stroke && y >= margin+2+stroke && y < size-margin-2-stroke
			if inOuter && !inInner {
				pixels[y*size+x] = 0xFFDC2626 // opaque, in 0xAARRGGBB
			} else {
				pixels[y*size+x] = 0
			}
		}
	}

	// The mask is required by the API but ignored for a colour bitmap that
	// carries its own alpha channel.
	var maskBits [size * size / 8]byte
	mask, _, _ := procCreateBitmap.Call(size, size, 1, 1, uintptr(unsafe.Pointer(&maskBits[0])))
	if mask == 0 {
		return stock
	}
	defer deleteObject(mask)

	info := iconInfo{isIcon: 1, mask: mask, color: color}
	icon, _, _ := procCreateIconIndirect.Call(uintptr(unsafe.Pointer(&info)))
	if icon == 0 {
		return stock
	}
	return icon
}
