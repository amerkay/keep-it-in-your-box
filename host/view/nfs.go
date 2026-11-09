package main

// The view as an NFSv3 server on 127.0.0.1, for kib's VM to mount (the same on Linux and
// macOS). Every check is the core's (view.go); this maps go-nfs's billy calls onto it.
// NFS is stateless: each READ/WRITE reopens the file, so there is no close to hang a mirror's
// size check on (mirrorLater), and the owner may write their own read-only file (ownerWrite).
//
// Reachable by every box (they reach the host at Lima's address) and every local account, so
// a mount needs the secret path printed at start, and only the first one is served. Handles
// are random 128-bit ids, never derived from a path or inode. (PLAN_NFS_VIEW.md)

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"path"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	billy "github.com/go-git/go-billy/v5"
	nfs "github.com/willscott/go-nfs"
	nfsfile "github.com/willscott/go-nfs/file"
)

// serveNFS listens on a random loopback port, prints "<port> <secret>" and serves until
// SIGTERM; SIGHUP reloads the rules.
func serveNFS(v *view, build func() []Rule) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		die(1, "kib-view: %v", err)
	}
	h := newHandler(v)
	fmt.Printf("%d %s\n", l.Addr().(*net.TCPAddr).Port, h.secret)
	nfs.Log.SetLevel(nfs.FatalLevel) // its errors are refusals we log, or the client's EXCLUSIVE-create fallback
	onSignals(func() {
		rules := build()
		v.setRules(rules)
		logf("kib-view: reloaded rules=%v", rules)
	}, func() {
		v.dropSillies()
		os.Exit(0)
	})
	die(1, "kib-view: %v", nfs.Serve(l, h))
}

type handler struct {
	fs      *nfsFS
	secret  string
	mounted atomic.Bool
	mu      sync.Mutex
	// ponytail: never shrinks, one entry per path ever looked up; an LRU if a project outgrows it.
	byID   map[[16]byte]string
	byPath map[string][16]byte
}

func newHandler(v *view) *handler {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		die(1, "kib-view: %v", err)
	}
	return &handler{fs: &nfsFS{v: v}, secret: hex.EncodeToString(b[:]),
		byID: map[[16]byte]string{}, byPath: map[string][16]byte{}}
}

// Mount serves the secret path, once: kib's own mount, never a second client.
func (h *handler) Mount(ctx context.Context, c net.Conn, req nfs.MountRequest) (nfs.MountStatus, billy.Filesystem, []nfs.AuthFlavor) {
	if string(req.Dirpath) != "/"+h.secret || !h.mounted.CompareAndSwap(false, true) {
		logf("kib-view: refused a mount from %v", c.RemoteAddr())
		return nfs.MountStatusErrAcces, nil, nil
	}
	return nfs.MountStatusOk, h.fs, []nfs.AuthFlavor{nfs.AuthFlavorNull}
}

// Change: no nfs.UnixChange, so no LINK. go-nfs v0.0.4 parses LINK's arguments as SYMLINK's;
// git falls back to a rename.
func (h *handler) Change(billy.Filesystem) billy.Change { return h.fs }

func (h *handler) FSStat(context.Context, billy.Filesystem, *nfs.FSStat) error { return nil }

func (h *handler) ToHandle(_ billy.Filesystem, p []string) []byte {
	key := strings.Join(p, "/")
	h.mu.Lock()
	defer h.mu.Unlock()
	id, ok := h.byPath[key]
	if !ok {
		if _, err := rand.Read(id[:]); err != nil {
			die(1, "kib-view: %v", err)
		}
		h.byID[id], h.byPath[key] = key, id
	}
	return id[:]
}

func (h *handler) FromHandle(fh []byte) (billy.Filesystem, []string, error) {
	var id [16]byte
	copy(id[:], fh)
	h.mu.Lock()
	key, ok := h.byID[id]
	h.mu.Unlock()
	if len(fh) != len(id) || !ok {
		return nil, nil, &nfs.NFSStatusError{NFSStatus: nfs.NFSStatusStale}
	}
	if key == "" {
		return h.fs, []string{}, nil
	}
	return h.fs, strings.Split(key, "/"), nil
}

func (h *handler) InvalidateHandle(_ billy.Filesystem, fh []byte) error {
	var id [16]byte
	copy(id[:], fh)
	h.mu.Lock()
	defer h.mu.Unlock()
	if key, ok := h.byID[id]; ok && key != "" {
		delete(h.byID, id)
		delete(h.byPath, key)
	}
	return nil
}

func (h *handler) HandleLimit() int { return 1 << 20 }

// nfsFS is the view as go-billy, which go-nfs serves. A name is cleaned to a path beneath the
// project ("" is its root) before anything sees it.
type nfsFS struct {
	v       *view
	ownerMu sync.Mutex
}

func clean(name string) string { return strings.TrimPrefix(path.Clean("/"+name), "/") }

func pathErr(op, name string, e syscall.Errno) error {
	if e == 0 {
		return nil
	}
	return &os.PathError{Op: op, Path: name, Err: e}
}

func (f *nfsFS) Join(elem ...string) string { return path.Join(elem...) }

func (f *nfsFS) Create(name string) (billy.File, error) {
	return f.OpenFile(name, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o666)
}

func (f *nfsFS) Open(name string) (billy.File, error) { return f.OpenFile(name, os.O_RDONLY, 0) }

func (f *nfsFS) OpenFile(name string, flag int, perm os.FileMode) (billy.File, error) {
	rel := clean(name)
	var h *handle
	var e syscall.Errno
	if flag&os.O_CREATE != 0 {
		h, e = f.v.create(rel, flag, uint32(perm.Perm()))
	} else {
		h, e = f.v.open(rel, flag)
		if e == syscall.EACCES && flag&writeFlags != 0 {
			h, e = f.ownerWrite(rel, flag)
		}
	}
	if e != 0 {
		return nil, pathErr("open", name, e)
	}
	return &nfsFileHandle{fs: f, rel: rel, h: h}, nil
}

// ownerWrite opens the owner's own read-only file for writing, as a local open of a file it
// created would: git makes objects 0444, then writes them over NFS. u+w for the open only.
func (f *nfsFS) ownerWrite(rel string, flag int) (*handle, syscall.Errno) {
	f.ownerMu.Lock()
	defer f.ownerMu.Unlock()
	st, err := f.v.lstatAt(rel)
	if err != nil || int(st.Uid) != os.Getuid() || st.Mode&0o200 != 0 {
		return nil, syscall.EACCES
	}
	mode := uint32(st.Mode) & 0o7777
	if f.v.chmodAt(rel, mode|0o200) != nil {
		return nil, syscall.EACCES
	}
	defer f.v.chmodAt(rel, mode)
	return f.v.open(rel, flag)
}

func (f *nfsFS) Stat(name string) (os.FileInfo, error) { return f.Lstat(name) }

func (f *nfsFS) Lstat(name string) (os.FileInfo, error) {
	rel := clean(name)
	st, e := f.v.stat(rel)
	if e != 0 {
		return nil, pathErr("lstat", name, e)
	}
	return fileInfo{name: path.Base("/" + rel), st: st}, nil
}

func (f *nfsFS) Rename(from, to string) error {
	return pathErr("rename", from, f.v.rename(clean(from), clean(to), 0))
}

func (f *nfsFS) Remove(name string) error {
	rel := clean(name)
	if st, e := f.v.stat(rel); e == 0 && st.Mode&syscall.S_IFMT == syscall.S_IFDIR {
		return pathErr("rmdir", name, f.v.rmdir(rel))
	}
	return pathErr("unlink", name, f.v.unlink(rel))
}

func (f *nfsFS) TempFile(string, string) (billy.File, error) { return nil, billy.ErrNotSupported }

func (f *nfsFS) ReadDir(name string) ([]os.FileInfo, error) {
	rel := clean(name)
	ents, e := f.v.list(rel)
	if e != 0 {
		return nil, pathErr("readdir", name, e)
	}
	out := make([]os.FileInfo, 0, len(ents))
	for _, d := range ents {
		if st, e := f.v.stat(path.Join(rel, d.name)); e == 0 { // gone since the listing: skip
			out = append(out, fileInfo{name: d.name, st: st})
		}
	}
	return out, nil
}

// MkdirAll makes the one directory NFS asks for; go-nfs has checked its parent.
func (f *nfsFS) MkdirAll(name string, perm os.FileMode) error {
	return pathErr("mkdir", name, f.v.mkdir(clean(name), uint32(perm.Perm())))
}

func (f *nfsFS) Symlink(target, link string) error {
	return pathErr("symlink", link, f.v.symlink(target, clean(link)))
}

func (f *nfsFS) Readlink(name string) (string, error) {
	t, e := f.v.readlink(clean(name))
	return t, pathErr("readlink", name, e)
}

func (f *nfsFS) Chroot(string) (billy.Filesystem, error) { return nil, billy.ErrNotSupported }
func (f *nfsFS) Root() string                            { return f.v.src }

func (f *nfsFS) Chmod(name string, mode os.FileMode) error {
	return pathErr("chmod", name, f.v.chmod(clean(name), uint32(mode.Perm())))
}

func (f *nfsFS) Lchown(name string, uid, gid int) error {
	return pathErr("chown", name, f.v.chown(clean(name), uid, gid))
}

func (f *nfsFS) Chown(name string, uid, gid int) error { return f.Lchown(name, uid, gid) }

func (f *nfsFS) Chtimes(name string, atime, mtime time.Time) error {
	return pathErr("chtimes", name, f.v.utimes(clean(name), &atime, &mtime))
}

// fileInfo carries the view's stat to go-nfs, owner and inode included (nfsfile.FileInfo).
type fileInfo struct {
	name string
	st   syscall.Stat_t
}

func (i fileInfo) Name() string       { return i.name }
func (i fileInfo) Size() int64        { return i.st.Size }
func (i fileInfo) ModTime() time.Time { return mtime(&i.st) }
func (i fileInfo) IsDir() bool        { return i.st.Mode&syscall.S_IFMT == syscall.S_IFDIR }
func (i fileInfo) Sys() any {
	return nfsfile.FileInfo{Nlink: uint32(i.st.Nlink), UID: i.st.Uid, GID: i.st.Gid, Fileid: i.st.Ino}
}

func (i fileInfo) Mode() os.FileMode {
	m := os.FileMode(i.st.Mode & 0o777)
	switch i.st.Mode & syscall.S_IFMT {
	case syscall.S_IFDIR:
		m |= os.ModeDir
	case syscall.S_IFLNK:
		m |= os.ModeSymlink
	case syscall.S_IFREG:
	default:
		m |= os.ModeIrregular
	}
	return m
}

// nfsFileHandle is one READ or WRITE's open file.
type nfsFileHandle struct {
	fs  *nfsFS
	rel string
	h   *handle
	off int64
}

func (f *nfsFileHandle) Name() string  { return f.rel }
func (f *nfsFileHandle) Lock() error   { return nil }
func (f *nfsFileHandle) Unlock() error { return nil }

func (f *nfsFileHandle) ReadAt(p []byte, off int64) (int, error) {
	data := f.fs.v.served(f.rel, f.h)
	var n int
	if data == nil {
		var err error
		if n, err = syscall.Pread(f.h.fd, p, off); err != nil {
			return 0, err
		}
	} else if off < int64(len(data)) {
		n = copy(p, data[off:])
	}
	if n < len(p) {
		return n, io.EOF
	}
	return n, nil
}

func (f *nfsFileHandle) Read(p []byte) (int, error) {
	n, err := f.ReadAt(p, f.off)
	f.off += int64(n)
	return n, err
}

func (f *nfsFileHandle) Write(p []byte) (int, error) {
	n, e := f.fs.v.write(f.rel, f.h, p, f.off)
	f.off += int64(n)
	return n, pathErr("write", f.rel, e)
}

func (f *nfsFileHandle) Seek(off int64, whence int) (int64, error) {
	switch whence {
	case io.SeekCurrent:
		off += f.off
	case io.SeekEnd:
		st, e := f.fs.v.stat(f.rel)
		if e != 0 {
			return 0, e
		}
		off += st.Size
	}
	f.off = off
	return off, nil
}

func (f *nfsFileHandle) Truncate(size int64) error {
	return pathErr("truncate", f.rel, f.fs.v.truncate(f.rel, f.h.fd, size))
}

func (f *nfsFileHandle) Close() error {
	if f.h.fd >= 0 {
		syscall.Close(f.h.fd)
		f.h.fd = -1
	}
	if f.h.mirroring {
		f.fs.v.mirrorLater(f.rel)
	}
	return nil
}
