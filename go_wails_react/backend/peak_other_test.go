//go:build !windows

package backend

import (
	"os"
	"strconv"
	"strings"
)

// peakMB is the peak resident set (VmHWM) of the test process; 0 where /proc is missing
func peakMB() float64 {
	status, _ := os.ReadFile("/proc/self/status")
	for _, line := range strings.Split(string(status), "\n") {
		if f := strings.Fields(line); len(f) >= 2 && f[0] == "VmHWM:" {
			kb, _ := strconv.ParseFloat(f[1], 64)
			return kb / 1024
		}
	}
	return 0
}
