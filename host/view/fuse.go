//go:build linux

package main

// The view as a FUSE mount: the no-VM Linux mode's front end (rootless Docker cannot mount NFS).
// Every check is the core's (view.go); this is go-fuse's tree, page cache and directory streams.

import (
	"context"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// serveFUSE mounts v at mnt until SIGTERM/SIGINT; SIGHUP reloads the rules.
func serveFUSE(v *view, mnt string, build func() []Rule) {
	root := &node{v: v}
	server, err := fs.Mount(mnt, root, mountOptions())
	if err != nil {
		die(1, "kib-view: mount: %v", err)
	}
	onSignals(func() { reloadFUSE(v, root, build()) }, func() { _ = server.Unmount() })
	server.Wait()
}

// mountOptions: libfuse's 1 s entry and attr timeouts. No allow_other: the rootless box's root
// is this user, and Ubuntu refuses allow_other to users.
func mountOptions() *fs.Options {
	sec := time.Second
	return &fs.Options{
		EntryTimeout: &sec,
		AttrTimeout:  &sec,
		MountOptions: fuse.MountOptions{
			FsName: "kib-view",
			Name:   "kib",
			// The backing syscalls run as the server, so without this a `chmod 000` file reads
			// fine: the kernel re-checks owner and mode against the CALLER on every op.
			Options:       []string{"default_permissions"},
			DisableXAttrs: true,
		},
	}
}

// reloadFUSE swaps the rules and drops every cached page and name, so nothing the old rules
// served (a now-redacted file's real bytes) outlives them in the kernel.
func reloadFUSE(v *view, root *node, rules []Rule) {
	v.setRules(rules)
	var walk func(*fs.Inode)
	walk = func(in *fs.Inode) {
		for name, c := range in.Children() {
			c.NotifyContent(0, 0)
			in.NotifyEntry(name)
			walk(c)
		}
	}
	walk(&root.Inode)
	logf("kib-view: reloaded rules=%v", rules)
}

// node is one path in the view. Its path comes from go-fuse's tree, which renames keep.
type node struct {
	fs.Inode
	v *view

	mu         sync.Mutex // the open-time page cache stamp (libfuse's auto_cache)
	seen       bool
	mtime      uint64
	size       uint64
	generation uint64
}

var (
	_ fs.NodeLookuper   = (*node)(nil)
	_ fs.NodeGetattrer  = (*node)(nil)
	_ fs.NodeSetattrer  = (*node)(nil)
	_ fs.NodeReaddirer  = (*node)(nil)
	_ fs.NodeReadlinker = (*node)(nil)
	_ fs.NodeStatfser   = (*node)(nil)
	_ fs.NodeOpener     = (*node)(nil)
	_ fs.NodeCreater    = (*node)(nil)
	_ fs.NodeReader     = (*node)(nil)
	_ fs.NodeWriter     = (*node)(nil)
	_ fs.NodeFlusher    = (*node)(nil)
	_ fs.NodeFsyncer    = (*node)(nil)
	_ fs.NodeReleaser   = (*node)(nil)
	_ fs.NodeUnlinker   = (*node)(nil)
	_ fs.NodeRmdirer    = (*node)(nil)
	_ fs.NodeMkdirer    = (*node)(nil)
	_ fs.NodeRenamer    = (*node)(nil)
	_ fs.NodeLinker     = (*node)(nil)
	_ fs.NodeSymlinker  = (*node)(nil)
)

func (n *node) rel() string { return n.Path(nil) }

func (n *node) child(name string) string { return filepath.Join(n.rel(), name) }

func (n *node) attr(rel string, out *fuse.Attr) syscall.Errno {
	st, errno := n.v.stat(rel)
	if errno == 0 {
		out.FromStat(&st)
	}
	return errno
}

func (n *node) newChild(ctx context.Context, rel string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	if errno := n.attr(rel, &out.Attr); errno != 0 {
		return nil, errno
	}
	return n.NewInode(ctx, &node{v: n.v}, fs.StableAttr{Mode: out.Attr.Mode & syscall.S_IFMT, Ino: out.Attr.Ino}), 0
}

func (n *node) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	return n.newChild(ctx, n.child(name), out)
}

func (n *node) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	if h, ok := f.(*handle); ok && h.fd >= 0 && n.v.served(n.rel(), h) == nil { // may be unlinked
		var st syscall.Stat_t
		if err := syscall.Fstat(h.fd, &st); err != nil {
			return fs.ToErrno(err)
		}
		out.FromStat(&st)
		out.Ino = n.StableAttr().Ino
		return 0
	}
	errno := n.attr(n.rel(), &out.Attr)
	out.Ino = n.StableAttr().Ino
	return errno
}

func (n *node) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	ds, errno := n.list()
	if errno != 0 {
		return nil, errno
	}
	return &freshDir{DirStream: ds, relist: n.list}, 0
}

// freshDir re-lists on a rewind. gVisor keeps a directory open and seeks back to 0 to list it
// again; go-fuse's stream replays its first read, which froze every listing in the box.
type freshDir struct {
	fs.DirStream
	relist func() (fs.DirStream, syscall.Errno)
}

func (d *freshDir) Seekdir(ctx context.Context, off uint64) syscall.Errno {
	if off == 0 {
		ds, errno := d.relist()
		if errno == 0 {
			d.DirStream.Close()
			d.DirStream = ds
		}
		return errno
	}
	if sd, ok := d.DirStream.(fs.FileSeekdirer); ok {
		return sd.Seekdir(ctx, off)
	}
	return syscall.ENOTSUP
}

// list reads the directory now. With . and .., so a finished read ends past offset 0 and
// go-fuse calls Seekdir(0) on a rewind even when the directory is empty.
func (n *node) list() (fs.DirStream, syscall.Errno) {
	ents, errno := n.v.list(n.rel())
	if errno != 0 {
		return nil, errno
	}
	list := []fuse.DirEntry{{Name: ".", Mode: syscall.S_IFDIR, Ino: fuse.FUSE_UNKNOWN_INO},
		{Name: "..", Mode: syscall.S_IFDIR, Ino: fuse.FUSE_UNKNOWN_INO}}
	for _, e := range ents {
		list = append(list, fuse.DirEntry{Name: e.name, Mode: e.mode, Ino: fuse.FUSE_UNKNOWN_INO})
	}
	return fs.NewListDirStream(list), 0
}

func (n *node) Readlink(ctx context.Context) ([]byte, syscall.Errno) {
	t, errno := n.v.readlink(n.rel())
	return []byte(t), errno
}

func (n *node) Statfs(ctx context.Context, out *fuse.StatfsOut) syscall.Errno {
	var s syscall.Statfs_t
	if err := syscall.Statfs(n.v.src, &s); err != nil {
		return fs.ToErrno(err)
	}
	out.FromStatfsT(&s)
	return 0
}

// keep says whether the kernel may keep its page cache: only while mtime and size are what the
// last open saw, under the same rules (the host edits this tree).
func (n *node) keep(rel string) uint32 {
	var a fuse.Attr
	if n.attr(rel, &a) != 0 {
		return 0
	}
	gen := n.v.generation.Load()
	n.mu.Lock()
	defer n.mu.Unlock()
	same := n.seen && n.mtime == a.Mtime*1e9+uint64(a.Mtimensec) && n.size == a.Size &&
		n.generation == gen
	n.seen, n.mtime, n.size, n.generation = true, a.Mtime*1e9+uint64(a.Mtimensec), a.Size, gen
	if same {
		return fuse.FOPEN_KEEP_CACHE
	}
	return 0
}

// openFlags: what the kernel sends, less what openat2 refuses (EINVAL) — the exec marker — and
// O_APPEND: the kernel already gives each write its offset, and pwrite on an O_APPEND fd ignores it.
func openFlags(flags uint32) int {
	return int(flags &^ (syscall.O_APPEND | fuse.FMODE_EXEC))
}

func (n *node) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	rel := n.rel()
	h, errno := n.v.open(rel, openFlags(flags))
	if errno != 0 {
		return nil, 0, errno
	}
	return h, n.keep(rel), 0
}

func (n *node) Create(ctx context.Context, name string, flags, mode uint32, out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	rel := n.child(name)
	h, errno := n.v.create(rel, openFlags(flags), mode)
	if errno != 0 {
		return nil, nil, 0, errno
	}
	child, errno := n.newChild(ctx, rel, out)
	if errno != 0 {
		syscall.Close(h.fd)
		return nil, nil, 0, errno
	}
	return child, h, 0, 0
}

// pread/pwrite, never lseek+read: concurrent requests share the fd's one offset.
func (n *node) Read(ctx context.Context, f fs.FileHandle, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	h := f.(*handle)
	data := n.v.served(n.rel(), h)
	if data == nil {
		return fuse.ReadResultFd(uintptr(h.fd), off, len(dest)), 0
	}
	end := min(off+int64(len(dest)), int64(len(data)))
	return fuse.ReadResultData(data[min(off, end):end]), 0
}

func (n *node) Write(ctx context.Context, f fs.FileHandle, data []byte, off int64) (uint32, syscall.Errno) {
	w, errno := n.v.write(n.rel(), f.(*handle), data, off)
	return uint32(w), errno
}

// Flush is not an fsync (it runs on every close(2), and writes go straight to the backing fd),
// but it is where a mirror's size is checked: close() returns its errno, release's it drops.
func (n *node) Flush(ctx context.Context, f fs.FileHandle) syscall.Errno {
	return n.v.wholeMirror(n.rel(), f.(*handle))
}

func (n *node) Fsync(ctx context.Context, f fs.FileHandle, flags uint32) syscall.Errno {
	if h, ok := f.(*handle); ok && h.fd >= 0 {
		return fs.ToErrno(syscall.Fsync(h.fd))
	}
	return 0
}

func (n *node) Release(ctx context.Context, f fs.FileHandle) syscall.Errno {
	h := f.(*handle)
	if h.fd >= 0 {
		syscall.Close(h.fd)
	}
	return n.v.wholeMirror(n.rel(), h)
}

func (n *node) Setattr(ctx context.Context, f fs.FileHandle, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	rel := n.rel()
	if sz, ok := in.GetSize(); ok {
		fd := -1
		if h, ok := f.(*handle); ok {
			fd = h.fd
		}
		if errno := n.v.truncate(rel, fd, int64(sz)); errno != 0 {
			return errno
		}
	}
	if errno := n.v.deny(rel, true); errno != 0 {
		return errno
	}
	if m, ok := in.GetMode(); ok {
		if errno := n.v.chmod(rel, m); errno != 0 {
			return errno
		}
	}
	uid, uok := in.GetUID()
	gid, gok := in.GetGID()
	if uok || gok {
		u, g := -1, -1
		if uok {
			u = int(uid)
		}
		if gok {
			g = int(gid)
		}
		if errno := n.v.chown(rel, u, g); errno != 0 {
			return errno
		}
	}
	var times [2]*time.Time
	if a, ok := in.GetATime(); ok {
		times[0] = &a
	}
	if m, ok := in.GetMTime(); ok {
		times[1] = &m
	}
	if times[0] != nil || times[1] != nil {
		if errno := n.v.utimes(rel, times[0], times[1]); errno != 0 {
			return errno
		}
	}
	return n.Getattr(ctx, f, out)
}

func (n *node) Unlink(ctx context.Context, name string) syscall.Errno {
	return n.v.unlink(n.child(name))
}

func (n *node) Rmdir(ctx context.Context, name string) syscall.Errno {
	return n.v.rmdir(n.child(name))
}

func (n *node) Mkdir(ctx context.Context, name string, mode uint32, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := n.child(name)
	if errno := n.v.mkdir(rel, mode); errno != 0 {
		return nil, errno
	}
	return n.newChild(ctx, rel, out)
}

func (n *node) Rename(ctx context.Context, name string, newParent fs.InodeEmbedder, newName string, flags uint32) syscall.Errno {
	return n.v.rename(n.child(name), filepath.Join(newParent.EmbeddedInode().Path(nil), newName), flags)
}

func (n *node) Link(ctx context.Context, target fs.InodeEmbedder, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := n.child(name)
	if errno := n.v.link(target.EmbeddedInode().Path(nil), rel); errno != 0 {
		return nil, errno
	}
	return n.newChild(ctx, rel, out)
}

func (n *node) Symlink(ctx context.Context, target, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := n.child(name)
	if errno := n.v.symlink(target, rel); errno != 0 {
		return nil, errno
	}
	return n.newChild(ctx, rel, out)
}
