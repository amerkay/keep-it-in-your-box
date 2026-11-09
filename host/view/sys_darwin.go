package main

import (
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	dirFlags  = unix.O_RDONLY | unix.O_DIRECTORY
	utimeOmit = -2 // <sys/stat.h>
)

// openBeneath: macOS has no openat2, so a clean relative path (no "..") plus O_NOFOLLOW_ANY,
// which refuses a symlink in any component.
func openBeneath(dirfd int, rel string, flags int, mode uint32) (int, error) {
	if strings.HasPrefix(rel, "/") || rel == ".." || strings.HasPrefix(rel, "../") ||
		strings.Contains(rel, "/../") || strings.HasSuffix(rel, "/..") {
		return -1, syscall.EXDEV
	}
	return unix.Openat(dirfd, rel, flags|unix.O_NOFOLLOW_ANY|unix.O_CLOEXEC, mode)
}

func (v *view) chmodAt(rel string, mode uint32) error {
	return v.inParent(rel, func(dfd int, name string) error {
		return unix.Fchmodat(dfd, name, mode, unix.AT_SYMLINK_NOFOLLOW)
	})
}

func renameAt(odfd int, o string, ddfd int, d string, flags uint) error {
	if flags != 0 {
		return syscall.EINVAL
	}
	return unix.Renameat(odfd, o, ddfd, d)
}

func mtime(st *syscall.Stat_t) time.Time { return time.Unix(st.Mtimespec.Unix()) }
