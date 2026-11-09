//go:build linux

package main

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"slices"
	"syscall"
	"testing"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// gVisor lists a directory by seeking its open fd back to 0: a rewind must re-read, not replay.
func TestFreshDirRelistsOnRewind(t *testing.T) {
	reads := 0
	relist := func() (fs.DirStream, syscall.Errno) {
		reads++
		return fs.NewListDirStream(make([]fuse.DirEntry, reads)), 0
	}
	ds, _ := relist()
	d := &freshDir{DirStream: ds, relist: relist}
	if errno := d.Seekdir(context.Background(), 1); errno != 0 || reads != 1 {
		t.Fatalf("a seek past 0 re-listed or failed: errno %v, reads %d", errno, reads)
	}
	if errno := d.Seekdir(context.Background(), 0); errno != 0 || reads != 2 {
		t.Fatalf("a rewind replayed the first read: errno %v, reads %d", errno, reads)
	}
	n := 0
	for ; d.HasNext(); n++ {
		d.Next()
	}
	if n != 2 {
		t.Errorf("after the rewind, %d entries, want the fresh read's 2", n)
	}
}

// The same on a mount, for an empty directory too: it ended at offset 0, so go-fuse never
// called Seekdir until listings carried . and ..
func TestRewindRelists(t *testing.T) {
	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, "empty"), 0o755)
	os.WriteFile(filepath.Join(src, "old"), nil, 0o644)
	mnt, _ := mount(t, src, guardRules(t))
	for _, d := range []string{mnt, filepath.Join(mnt, "empty")} {
		f, err := os.Open(d)
		if err != nil {
			t.Fatal(err)
		}
		first, _ := f.Readdirnames(-1)
		os.WriteFile(filepath.Join(d, "new"), nil, 0o644)
		os.Remove(filepath.Join(d, "old"))
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			t.Fatal(err)
		}
		again, _ := f.Readdirnames(-1)
		f.Close()
		if !slices.Contains(again, "new") || slices.Contains(again, "old") {
			t.Errorf("%s: after a rewind %v (first read %v), want new and not old", d, again, first)
		}
	}
}
