package backend

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

var procGetProcessMemoryInfo = windows.NewLazySystemDLL("psapi.dll").NewProc("GetProcessMemoryInfo")

type memCounters struct {
	cb                                                         uint32
	pageFaults                                                 uint32
	peakWorkingSet, workingSet, quotaPeakPaged, quotaPaged     uintptr
	quotaPeakNonPaged, quotaNonPaged, pagefileUsage, peakPagef uintptr
}

// peakMB is the peak working set of the test process
func peakMB() float64 {
	var m memCounters
	m.cb = uint32(unsafe.Sizeof(m))
	procGetProcessMemoryInfo.Call(uintptr(windows.CurrentProcess()), uintptr(unsafe.Pointer(&m)), uintptr(m.cb))
	return float64(m.peakWorkingSet) / (1 << 20)
}
