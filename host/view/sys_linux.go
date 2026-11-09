package main

import (
	"strconv"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	dirFlags  = unix.O_PATH | unix.O_DIRECTORY
	utimeOmit = unix.UTIME_OMIT
)

// openBeneath opens rel under dirfd with no symlink anywhere on the way.
func openBeneath(dirfd int, rel string, flags int, mode uint32) (int, error) {
	return unix.Openat2(dirfd, rel, &unix.OpenHow{Flags: uint64(flags | unix.O_CLOEXEC),
		Mode: uint64(mode), Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS})
}

// chmodAt: chmod has no no-follow form here, so change the inode `at` opened, through its fd.
func (v *view) chmodAt(rel string, mode uint32) error {
	fd, err := v.at(rel, unix.O_PATH, 0)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	return unix.Fchmodat(unix.AT_FDCWD, "/proc/self/fd/"+strconv.Itoa(fd), mode, 0)
}

func renameAt(odfd int, o string, ddfd int, d string, flags uint) error {
	return unix.Renameat2(odfd, o, ddfd, d, flags)
}

func mtime(st *syscall.Stat_t) time.Time { return time.Unix(st.Mtim.Unix()) }
