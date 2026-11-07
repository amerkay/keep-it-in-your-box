package main

// The redacting view of --src at --mnt. Redacted paths refuse writes and read as their keys
// (Render) or the stub; protected paths read through and refuse writes, except a nested
// byte-identical copy of the same guarded tail at the ROOT (reproduce, never author). Every
// check and the syscall after it use the same path, and every syscall resolves it beneath --src
// with no symlink on the way (`at`), so nothing swapped in between can redirect it. An
// operation not implemented here is refused by go-fuse (xattrs, mknod, fallocate).
// Spec: tests/fixtures/redaction/fs.json; history: docs/design-notes/redaction-config-guard.md.

import (
	"bytes"
	"context"
	"encoding/binary"
	"hash/fnv"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
	"golang.org/x/sys/unix"
)

const (
	redactedName = "REDACTED.md"
	refused      = syscall.EPERM // the guard's errno; EACCES stays default_permissions'
	writeFlags   = syscall.O_WRONLY | syscall.O_RDWR | syscall.O_APPEND | syscall.O_CREAT |
		syscall.O_TRUNC
	verdictMax = 1 << 16
	renderKeep = 64
)

var gitdirMarkers = []string{"HEAD", "objects", "refs"}

type kind int

const (
	pass   kind = iota
	file        // a masked file, or a path under one: serve its render
	dir         // a masked directory: serve one REDACTED.md
	inside      // under a masked directory: REDACTED.md or ENOENT
	absent      // masked, but not on the host: ENOENT on read, still refused on write
)

// rules is one rule set and its verdict memo, swapped whole on reload so a lookup racing the
// swap can never store an old verdict under the new rules.
type ruleSet struct {
	rules []Rule
	mu    sync.Mutex
	memo  map[string]string
}

type renderKey struct {
	path       string
	ino, mtime uint64
	size       int64
}

type view struct {
	src              string
	srcfd            int   // O_PATH: every syscall resolves beneath it
	uid, gid         int64 // -1: report the real ids
	baseUID, baseGID uint32
	rules            atomic.Pointer[ruleSet]
	generation       atomic.Uint64 // bumped on reload: no cached page survives a rule change
	renderMu         sync.Mutex
	renders          map[renderKey][]byte
	root             *node
}

func newView(src string, rules []Rule, uid, gid int64) (*view, error) {
	real, err := filepath.EvalSymlinks(src)
	if err != nil {
		return nil, err
	}
	var st syscall.Stat_t
	if err := syscall.Lstat(real, &st); err != nil {
		return nil, err
	}
	fd, err := unix.Open(real, unix.O_PATH|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	v := &view{src: real, srcfd: fd, uid: uid, gid: gid, baseUID: st.Uid, baseGID: st.Gid,
		renders: map[renderKey][]byte{}}
	v.setRules(rules)
	v.root = &node{v: v}
	return v, nil
}

func (v *view) setRules(rules []Rule) {
	v.rules.Store(&ruleSet{rules: rules, memo: map[string]string{}})
	v.generation.Add(1)
}

func (v *view) real(rel string) string { return filepath.Join(v.src, rel) }

// at opens rel beneath --src with no symlink anywhere on the way: the kernel resolved every
// link through the view already, so one here was planted after the check.
func (v *view) at(rel string, flags int, mode uint32) (int, error) {
	if rel == "" {
		rel = "."
	}
	return unix.Openat2(v.srcfd, rel, &unix.OpenHow{Flags: uint64(flags | unix.O_CLOEXEC),
		Mode: uint64(mode), Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS})
}

// inParent runs fn on rel's directory (opened as `at` does) and base name.
func (v *view) inParent(rel string, fn func(dfd int, name string) error) error {
	dfd, err := v.at(filepath.Dir(rel), unix.O_PATH|unix.O_DIRECTORY, 0)
	if err != nil {
		return err
	}
	defer unix.Close(dfd)
	return fn(dfd, filepath.Base(rel))
}

// readAt reads up to max bytes of rel, resolved as `at` does.
func (v *view) readAt(rel string, max int64) ([]byte, error) {
	fd, err := v.at(rel, unix.O_RDONLY|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), rel)
	defer f.Close()
	return io.ReadAll(io.LimitReader(f, max))
}

func (v *view) lstatAt(rel string) (unix.Stat_t, error) {
	var st unix.Stat_t
	err := v.inParent(rel, func(dfd int, name string) error {
		return unix.Fstatat(dfd, name, &st, unix.AT_SYMLINK_NOFOLLOW)
	})
	return st, err
}

// verdict is memoised: within one rule set it is a pure function of the path.
func (v *view) verdict(rel string) string {
	rs := v.rules.Load()
	rs.mu.Lock()
	got, ok := rs.memo[rel]
	rs.mu.Unlock()
	if ok {
		return got
	}
	got = Verdict(rs.rules, rel)
	rs.mu.Lock()
	if len(rs.memo) >= verdictMax {
		rs.memo = map[string]string{}
	}
	rs.memo[rel] = got
	rs.mu.Unlock()
	return got
}

func lexists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// classify finds the shallowest redacted ancestor. Only the RULE verdict is memoised: whether
// the path exists is asked live, so a file appearing or vanishing is seen at once.
func (v *view) classify(rel string) (kind, string) {
	if rel == "" {
		return pass, ""
	}
	parts := strings.Split(rel, "/")
	for i := 1; i <= len(parts); i++ {
		anc := strings.Join(parts[:i], "/")
		if v.verdict(anc) != Redact {
			continue
		}
		real := v.real(anc)
		if !lexists(real) {
			return absent, anc // redaction hides values; it never conjures files
		}
		d := isDir(real)
		switch {
		case i == len(parts) && d:
			return dir, anc
		case i == len(parts) || !d:
			return file, anc
		}
		return inside, anc
	}
	return pass, ""
}

func lowerParts(rel string) []string { return strings.Split(strings.ToLower(rel), "/") }

func (v *view) isGitdir(rel string) bool {
	for _, m := range gitdirMarkers {
		if _, err := os.Stat(filepath.Join(v.real(rel), m)); err != nil {
			return false
		}
	}
	return true
}

func (v *view) isGitConfig(rel string) bool {
	p := lowerParts(rel)
	last := p[len(p)-1]
	if len(p) < 2 || (last != "config" && last != "config.worktree") {
		return false
	}
	return contains(p[:len(p)-1], ".git") || v.isGitdir(filepath.Dir(rel))
}

// gitSensitive covers git's own executed paths at any nesting (submodules, worktrees, a bare
// or redirected git dir known by its layout): depth-aware, so code, not a guard pattern.
func (v *view) gitSensitive(rel string) bool {
	if v.isGitConfig(rel) {
		return true
	}
	p := lowerParts(rel)
	for i, x := range p {
		if x == "hooks" {
			return i >= 1 && (contains(p[:i], ".git") ||
				v.isGitdir(strings.Join(strings.Split(rel, "/")[:i], "/")))
		}
	}
	return false
}

func (v *view) protected(rel string) bool {
	return rel != "" && (v.verdict(rel) == Protect || v.gitSensitive(rel))
}

// mirrorAnchor is the root-anchored twin a nested guarded path may reproduce byte for byte:
// the shortest suffix that is still PROTECT. Never git's own paths, never [redact], never the
// anchor itself — which is what makes a copy of it safe.
func (v *view) mirrorAnchor(rel string) string {
	if v.gitSensitive(rel) || v.verdict(rel) != Protect {
		return ""
	}
	parts := strings.Split(rel, "/")
	for i := len(parts) - 1; i > 0; i-- {
		if s := strings.Join(parts[i:], "/"); v.verdict(s) == Protect {
			return s
		}
	}
	return ""
}

func (v *view) mirrorable(rel string) bool {
	a := v.mirrorAnchor(rel)
	return a != "" && lexists(v.real(a))
}

// throughRule: a multi-component rule passes through this directory, so moving it would carry
// files out of (`secrets` for `secrets/key.pem`) or into (`.zed` for `.zed/tasks.json`) the
// rule's reach. Negations count too: moving onto `!certs/pub.pem`'s path un-redacts.
func throughRule(rules []Rule, dir []string) bool {
	for i := range rules {
		r := &rules[i]
		if len(r.parts) < 2 {
			continue
		}
		for k := 1; k < len(r.parts) && k <= len(dir); k++ {
			if r.Anchor == exact && k != len(dir) {
				continue
			}
			ok := true
			for j := 0; j < k && ok; j++ {
				ok = fnmatch(dir[len(dir)-k+j], r.parts[j])
			}
			if ok {
				return true
			}
		}
	}
	return false
}

// denyDirMove refuses moving a directory a multi-component rule passes through, one named
// .git or laid out as a git dir, or one crossing into or out of .git (where bare rules stop).
func (v *view) denyDirMove(old, dst string) syscall.Errno {
	rules := v.rules.Load().rules
	o, d := lowerParts(old), lowerParts(dst)
	if o[len(o)-1] == ".git" || d[len(d)-1] == ".git" || v.isGitdir(old) ||
		throughRule(rules, o) || throughRule(rules, d) ||
		(strings.Split(old, "/")[0] == ".git") != (strings.Split(dst, "/")[0] == ".git") {
		logf("kib-fuse: refusing to move directory %s to %s (a guard rule spans it)", old, dst)
		return refused
	}
	return 0
}

// plantsGitdir: rel adds the last of HEAD/objects/refs to a directory whose hooks or config
// were written before it was a git dir, so never checked.
func (v *view) plantsGitdir(rel string) bool {
	base, d := filepath.Base(rel), filepath.Dir(rel)
	found := false
	for _, m := range gitdirMarkers {
		if strings.EqualFold(m, base) {
			found = true
		} else if _, err := v.lstatAt(filepath.Join(d, m)); err != nil {
			return false
		}
	}
	if !found {
		return false
	}
	if fd, err := v.at(filepath.Join(d, "hooks"), unix.O_RDONLY|unix.O_DIRECTORY, 0); err == nil {
		f := os.NewFile(uintptr(fd), "hooks")
		names, _ := f.Readdirnames(1)
		f.Close()
		if len(names) > 0 {
			return true
		}
	}
	for _, c := range []string{"config", "config.worktree"} {
		if b, err := v.readAt(filepath.Join(d, c), 1<<20); err == nil && len(GitIniEntries(string(b))) > 0 {
			return true
		}
	}
	return false
}

// denyNew is deny for an op that makes a new name, which may also complete a git dir.
func (v *view) denyNew(rel string, mirrorOK bool) syscall.Errno {
	if errno := v.deny(rel, mirrorOK); errno != 0 {
		return errno
	}
	if v.plantsGitdir(rel) {
		logf("kib-fuse: refusing %s: it makes a git dir of unchecked hooks or config", rel)
		return refused
	}
	return 0
}

// deny refuses a write to a masked path. mirrorOK=false refuses even an exact copy, for the ops
// that move bytes the guard never compared (rename, link, symlink) or reshape one (truncate).
func (v *view) deny(rel string, mirrorOK bool) syscall.Errno {
	if k, _ := v.classify(rel); k != pass {
		logf("kib-fuse: refusing a write to %s (redacted)", rel)
		return refused
	}
	if v.protected(rel) && !(mirrorOK && v.mirrorable(rel)) {
		logf("kib-fuse: refusing a write to %s (protected)", rel)
		return refused
	}
	return 0
}

func (v *view) render(root string) []byte {
	fd, err := v.at(root, unix.O_RDONLY|unix.O_NONBLOCK, 0)
	if err != nil {
		return Stub
	}
	f := os.NewFile(uintptr(fd), root)
	defer f.Close()
	var st unix.Stat_t
	if unix.Fstat(fd, &st) != nil {
		return Stub
	}
	key := renderKey{root, st.Ino, uint64(st.Mtim.Nano()), st.Size}
	v.renderMu.Lock()
	hit, ok := v.renders[key]
	v.renderMu.Unlock()
	if ok {
		return hit
	}
	hit, _ = Render(f)
	v.renderMu.Lock()
	if len(v.renders) >= renderKeep {
		v.renders = map[renderKey][]byte{}
	}
	v.renders[key] = hit
	v.renderMu.Unlock()
	return hit
}

func (v *view) own(uid, gid uint32) (uint32, uint32) {
	if v.uid >= 0 && uid == v.baseUID {
		uid = uint32(v.uid)
	}
	if v.gid >= 0 && gid == v.baseGID {
		gid = uint32(v.gid)
	}
	return uid, gid
}

// attr fills out for rel, synthesising the masked shapes (timestamped from the masked root, so
// a watcher sees one file change, not the whole tree); ino is unique per path and real inode.
func (v *view) attr(rel string, out *fuse.Attr) (ino uint64, errno syscall.Errno) {
	k, root := v.classify(rel)
	var st syscall.Stat_t
	statPath := rel
	if k == file || k == dir || k == inside {
		statPath = root
	}
	if err := syscall.Lstat(v.real(statPath), &st); err != nil {
		return 0, fs.ToErrno(err)
	}
	out.FromStat(&st)
	switch k {
	case file:
		out.Mode, out.Nlink, out.Size = syscall.S_IFREG|0o444, 1, uint64(len(v.render(root)))
	case dir:
		out.Mode, out.Nlink, out.Size = syscall.S_IFDIR|0o555, 2, 0
	case inside:
		if filepath.Base(rel) != redactedName || filepath.Dir(rel) != root {
			return 0, syscall.ENOENT
		}
		out.Mode, out.Nlink, out.Size = syscall.S_IFREG|0o444, 1, uint64(len(Stub))
	}
	out.Uid, out.Gid = v.own(out.Uid, out.Gid)
	h := fnv.New64a()
	h.Write([]byte(rel))
	h.Write([]byte{0, byte(out.Mode >> 12), byte(k)})
	h.Write(binary.LittleEndian.AppendUint64(nil, st.Ino))
	ino = h.Sum64() | 1<<63
	out.Ino = ino
	return ino, 0
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

// unmasked: still a plain path under the CURRENT rules (a reload may have redacted it since).
func (n *node) unmasked() bool {
	k, _ := n.v.classify(n.rel())
	return k == pass
}

func (n *node) child(name string) string { return filepath.Join(n.rel(), name) }

func (n *node) newChild(ctx context.Context, rel string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	ino, errno := n.v.attr(rel, &out.Attr)
	if errno != 0 {
		return nil, errno
	}
	return n.NewInode(ctx, &node{v: n.v}, fs.StableAttr{Mode: out.Attr.Mode & syscall.S_IFMT, Ino: ino}), 0
}

func (n *node) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	return n.newChild(ctx, n.child(name), out)
}

func (n *node) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	if h, ok := f.(*handle); ok && h.fd >= 0 && n.unmasked() { // an open file may be unlinked
		var st syscall.Stat_t
		if err := syscall.Fstat(h.fd, &st); err != nil {
			return fs.ToErrno(err)
		}
		out.FromStat(&st)
		out.Uid, out.Gid = n.v.own(out.Uid, out.Gid)
		out.Ino = n.StableAttr().Ino
		return 0
	}
	_, errno := n.v.attr(n.rel(), &out.Attr)
	out.Ino = n.StableAttr().Ino
	return errno
}

func (n *node) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	switch k, _ := n.v.classify(n.rel()); k {
	case dir:
		return fs.NewListDirStream([]fuse.DirEntry{{Name: redactedName, Mode: syscall.S_IFREG}}), 0
	case file, inside:
		return fs.NewListDirStream(nil), 0
	}
	fd, err := n.v.at(n.rel(), unix.O_RDONLY|unix.O_DIRECTORY, 0)
	if err != nil {
		return nil, fs.ToErrno(err)
	}
	d := os.NewFile(uintptr(fd), n.rel())
	ents, err := d.ReadDir(-1)
	d.Close()
	if err != nil {
		return nil, fs.ToErrno(err)
	}
	list := make([]fuse.DirEntry, 0, len(ents))
	for _, e := range ents {
		mode := uint32(syscall.S_IFREG)
		if e.IsDir() {
			mode = syscall.S_IFDIR
		} else if e.Type()&os.ModeSymlink != 0 {
			mode = syscall.S_IFLNK
		}
		list = append(list, fuse.DirEntry{Name: e.Name(), Mode: mode, Ino: fuse.FUSE_UNKNOWN_INO})
	}
	return fs.NewListDirStream(list), 0
}

func (n *node) Readlink(ctx context.Context) ([]byte, syscall.Errno) {
	if !n.unmasked() {
		return nil, refused
	}
	buf := make([]byte, 4096)
	var got int
	err := n.v.inParent(n.rel(), func(dfd int, name string) (err error) {
		got, err = unix.Readlinkat(dfd, name, buf)
		return err
	})
	if err != nil {
		return nil, fs.ToErrno(err)
	}
	return buf[:got], 0
}

func (n *node) Statfs(ctx context.Context, out *fuse.StatfsOut) syscall.Errno {
	var s syscall.Statfs_t
	if err := syscall.Statfs(n.v.src, &s); err != nil {
		return fs.ToErrno(err)
	}
	out.FromStatfsT(&s)
	return 0
}

// handle is an open file: a real fd, or a synthesised render (fd -1).
type handle struct {
	fd        int
	data      []byte
	mirroring bool // opened for writing at a protected path: size-checked at release
}

// keep says whether the kernel may keep its page cache: only while mtime and size are what the
// last open saw, under the same rules (the host edits this tree).
func (n *node) keep(rel string) uint32 {
	var a fuse.Attr
	if _, errno := n.v.attr(rel, &a); errno != 0 {
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

func (n *node) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	rel := n.rel()
	k, root := n.v.classify(rel)
	if flags&writeFlags != 0 {
		// Nothing legitimate writes .git/config in place: git renames config.lock over it.
		if errno := n.v.deny(rel, true); errno != 0 {
			return nil, 0, errno
		}
	}
	switch k {
	case file:
		return &handle{fd: -1, data: n.v.render(root)}, n.keep(rel), 0
	case dir, inside:
		return &handle{fd: -1, data: Stub}, n.keep(rel), 0
	}
	fd, err := n.v.at(rel, openFlags(flags)&^syscall.O_CREAT, 0)
	if err != nil {
		return nil, 0, fs.ToErrno(err)
	}
	h := &handle{fd: fd, mirroring: flags&writeFlags != 0 && n.v.protected(rel)}
	return h, n.keep(rel), 0
}

// openFlags: what the kernel sends, less what openat2 refuses (EINVAL) — the exec marker — and
// O_APPEND: the kernel already gives each write its offset, and pwrite on an O_APPEND fd ignores it.
func openFlags(flags uint32) int {
	return int(flags &^ (syscall.O_APPEND | fuse.FMODE_EXEC))
}

// adopt hands a just-created inode to the caller: it lands on the HOST. Best effort (virtiofs
// ignores chown, and kib runs this server as the caller anyway).
func adopt(ctx context.Context, do func(uid, gid int) error) {
	if c, ok := fuse.FromContext(ctx); ok {
		_ = do(int(c.Uid), int(c.Gid))
	}
}

func (n *node) Create(ctx context.Context, name string, flags, mode uint32, out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	rel := n.child(name)
	if errno := n.v.denyNew(rel, true); errno != 0 {
		return nil, nil, 0, errno
	}
	fd, err := n.v.at(rel, openFlags(flags)|syscall.O_CREAT, mode&0o7777)
	if err != nil {
		return nil, nil, 0, fs.ToErrno(err)
	}
	adopt(ctx, func(u, g int) error { return syscall.Fchown(fd, u, g) })
	child, errno := n.newChild(ctx, rel, out)
	if errno != 0 {
		syscall.Close(fd)
		return nil, nil, 0, errno
	}
	return child, &handle{fd: fd, mirroring: n.v.protected(rel)}, 0, 0
}

// pread/pwrite, never lseek+read: concurrent requests share the fd's one offset.
func (n *node) Read(ctx context.Context, f fs.FileHandle, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	h := f.(*handle)
	data := h.data
	if h.fd >= 0 {
		k, root := n.v.classify(n.rel())
		if k == pass {
			return fuse.ReadResultFd(uintptr(h.fd), off, len(dest)), 0
		}
		data = Stub // opened before a reload redacted it: serve what a new open would
		if k == file {
			data = n.v.render(root)
		}
	}
	end := min(off+int64(len(dest)), int64(len(data)))
	return fuse.ReadResultData(data[min(off, end):end]), 0
}

// Write lets a mirror only REPRODUCE: each byte is compared with the anchor's at the same
// offset before it lands, so a payload is refused at its first differing byte.
func (n *node) Write(ctx context.Context, f fs.FileHandle, data []byte, off int64) (uint32, syscall.Errno) {
	h := f.(*handle)
	if h.fd < 0 {
		return 0, syscall.EBADF
	}
	rel := n.rel()
	if !n.unmasked() {
		return 0, refused
	}
	if n.v.protected(rel) && !bytes.Equal(data, n.v.anchorBytes(rel, off, len(data))) {
		logf("kib-fuse: refusing a write to %s (not a copy of its root anchor)", rel)
		return 0, refused
	}
	w, err := syscall.Pwrite(h.fd, data, off)
	return uint32(max(w, 0)), fs.ToErrno(err)
}

func (v *view) anchorBytes(rel string, off int64, size int) []byte {
	a := v.mirrorAnchor(rel)
	if a == "" {
		return nil
	}
	fd, err := v.at(a, unix.O_RDONLY|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil
	}
	defer unix.Close(fd)
	buf := make([]byte, size)
	got, _ := unix.Pread(fd, buf, off)
	return buf[:max(got, 0)]
}

// Flush is not an fsync (it runs on every close(2), and writes go straight to the backing fd),
// but it is where a mirror's size is checked: close() returns its errno, release's it drops.
func (n *node) Flush(ctx context.Context, f fs.FileHandle) syscall.Errno {
	return n.wholeMirror(f.(*handle))
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
	return n.wholeMirror(h)
}

// wholeMirror removes a mirror whose size is not its anchor's: a short copy matches byte for
// byte as far as it goes, and a truncated script is a different script. The unlink is the
// enforcement; the errno is a courtesy.
func (n *node) wholeMirror(h *handle) syscall.Errno {
	rel := n.rel()
	if !h.mirroring || !n.v.protected(rel) {
		return 0
	}
	if a := n.v.mirrorAnchor(rel); a != "" {
		got, err1 := n.v.lstatAt(rel)
		want, err2 := n.v.lstatAt(a)
		if err1 == nil && err2 == nil && got.Size == want.Size {
			return 0
		}
	}
	h.mirroring = false
	_ = n.v.inParent(rel, func(dfd int, name string) error { return unix.Unlinkat(dfd, name, 0) })
	logf("kib-fuse: removed %s: not a whole copy of its root anchor", rel)
	return refused
}

func (n *node) Setattr(ctx context.Context, f fs.FileHandle, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	rel := n.rel()
	if sz, ok := in.GetSize(); ok {
		// No mirror: a standalone truncate can only make a short copy.
		if errno := n.v.deny(rel, false); errno != 0 {
			return errno
		}
		fd := -1
		if h, ok := f.(*handle); ok {
			fd = h.fd
		}
		var err error
		if fd < 0 {
			if fd, err = n.v.at(rel, unix.O_WRONLY|unix.O_NONBLOCK, 0); err != nil {
				return fs.ToErrno(err)
			}
			defer unix.Close(fd)
		}
		if err := unix.Ftruncate(fd, int64(sz)); err != nil {
			return fs.ToErrno(err)
		}
	}
	if errno := n.v.deny(rel, true); errno != 0 {
		return errno
	}
	if m, ok := in.GetMode(); ok {
		// chmod has no no-follow form: change the inode `at` opened, through its fd.
		fd, err := n.v.at(rel, unix.O_PATH, 0)
		if err != nil {
			return fs.ToErrno(err)
		}
		err = unix.Fchmodat(unix.AT_FDCWD, "/proc/self/fd/"+strconv.Itoa(fd), m&0o7777, 0)
		unix.Close(fd)
		if err != nil {
			return fs.ToErrno(err)
		}
	}
	uid, uok := in.GetUID()
	gid, gok := in.GetGID()
	if uok || gok {
		// Under the remap the caller echoes back ids we invented (`cp -p`, `git checkout`):
		// forwarding them would re-own the real file. -1 keeps that half unchanged.
		u, g := -1, -1
		if uok && !(n.v.uid >= 0 && int64(uid) == n.v.uid) {
			u = int(uid)
		}
		if gok && !(n.v.gid >= 0 && int64(gid) == n.v.gid) {
			g = int(gid)
		}
		if err := n.v.inParent(rel, func(dfd int, name string) error {
			return unix.Fchownat(dfd, name, u, g, unix.AT_SYMLINK_NOFOLLOW)
		}); err != nil {
			return fs.ToErrno(err)
		}
	}
	atime, aok := in.GetATime()
	mtime, mok := in.GetMTime()
	if aok || mok {
		ts := []unix.Timespec{{Nsec: unix.UTIME_OMIT}, {Nsec: unix.UTIME_OMIT}}
		if aok {
			ts[0] = unix.NsecToTimespec(atime.UnixNano())
		}
		if mok {
			ts[1] = unix.NsecToTimespec(mtime.UnixNano())
		}
		if err := n.v.inParent(rel, func(dfd int, name string) error {
			return unix.UtimesNanoAt(dfd, name, ts, unix.AT_SYMLINK_NOFOLLOW)
		}); err != nil {
			return fs.ToErrno(err)
		}
	}
	return n.Getattr(ctx, f, out)
}

func (n *node) Unlink(ctx context.Context, name string) syscall.Errno {
	rel := n.child(name)
	if errno := n.v.deny(rel, true); errno != 0 {
		return errno
	}
	return fs.ToErrno(n.v.inParent(rel, func(dfd int, name string) error {
		return unix.Unlinkat(dfd, name, 0)
	}))
}

func (n *node) Rmdir(ctx context.Context, name string) syscall.Errno {
	rel := n.child(name)
	if errno := n.v.deny(rel, true); errno != 0 {
		return errno
	}
	return fs.ToErrno(n.v.inParent(rel, func(dfd int, name string) error {
		return unix.Unlinkat(dfd, name, unix.AT_REMOVEDIR)
	}))
}

func (n *node) Mkdir(ctx context.Context, name string, mode uint32, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := n.child(name)
	if errno := n.v.denyNew(rel, true); errno != 0 {
		return nil, errno
	}
	if err := n.v.inParent(rel, func(dfd int, name string) error {
		if err := unix.Mkdirat(dfd, name, mode); err != nil {
			return err
		}
		adopt(ctx, func(u, g int) error { return unix.Fchownat(dfd, name, u, g, unix.AT_SYMLINK_NOFOLLOW) })
		return nil
	}); err != nil {
		return nil, fs.ToErrno(err)
	}
	return n.newChild(ctx, rel, out)
}

// Rename moves bytes the guard never compared, so neither end may be a mirror, and a directory
// may not carry files across a rule (denyDirMove). The one validated write: git's config.lock
// renamed over a config, checked for new command keys.
func (n *node) Rename(ctx context.Context, name string, newParent fs.InodeEmbedder, newName string, flags uint32) syscall.Errno {
	if flags&^unix.RENAME_NOREPLACE != 0 {
		return syscall.EINVAL // an exchange would move the target too, unchecked
	}
	old := n.child(name)
	dst := filepath.Join(newParent.EmbeddedInode().Path(nil), newName)
	if errno := n.v.deny(old, false); errno != 0 {
		return errno
	}
	if st, err := n.v.lstatAt(old); err == nil && st.Mode&unix.S_IFMT == unix.S_IFDIR {
		if errno := n.v.denyDirMove(old, dst); errno != 0 {
			return errno
		}
	}
	if k, _ := n.v.classify(dst); k == pass && n.v.isGitConfig(dst) {
		cand, err := n.v.readAt(old, 1<<20)
		cur, curErr := n.v.readAt(dst, 1<<20)
		if err != nil || !gitConfigWriteOK(cand, cur, curErr) {
			return refused
		}
	} else if errno := n.v.denyNew(dst, false); errno != 0 {
		return errno
	}
	return fs.ToErrno(n.v.inParent(old, func(odfd int, oname string) error {
		return n.v.inParent(dst, func(ddfd int, dname string) error {
			return unix.Renameat2(odfd, oname, ddfd, dname, uint(flags))
		})
	}))
}

// Link checks the SOURCE too: a hardlink is a second name for the same inode, so an unguarded
// alias would launder a guarded file past every path check.
func (n *node) Link(ctx context.Context, target fs.InodeEmbedder, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := n.child(name)
	src := target.EmbeddedInode().Path(nil)
	if errno := n.v.denyNew(rel, false); errno != 0 {
		return nil, errno
	}
	if errno := n.v.deny(src, false); errno != 0 {
		return nil, errno
	}
	if err := n.v.inParent(src, func(sdfd int, sname string) error {
		return n.v.inParent(rel, func(dfd int, dname string) error {
			return unix.Linkat(sdfd, sname, dfd, dname, 0)
		})
	}); err != nil {
		return nil, fs.ToErrno(err)
	}
	return n.newChild(ctx, rel, out)
}

// Symlink: a link's content is a path, never the anchor's bytes, so no mirror.
func (n *node) Symlink(ctx context.Context, target, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := n.child(name)
	if errno := n.v.denyNew(rel, false); errno != 0 {
		return nil, errno
	}
	if err := n.v.inParent(rel, func(dfd int, name string) error {
		if err := unix.Symlinkat(target, dfd, name); err != nil {
			return err
		}
		// The link itself, never its target.
		adopt(ctx, func(u, g int) error { return unix.Fchownat(dfd, name, u, g, unix.AT_SYMLINK_NOFOLLOW) })
		return nil
	}); err != nil {
		return nil, fs.ToErrno(err)
	}
	return n.newChild(ctx, rel, out)
}

// reload swaps the rules on a live mount and drops every cached page and name, so nothing the
// old rules served (a now-redacted file's real bytes) outlives them in the kernel.
func (v *view) reload(rules []Rule) {
	v.setRules(rules)
	var walk func(*fs.Inode)
	walk = func(in *fs.Inode) {
		for name, c := range in.Children() {
			c.NotifyContent(0, 0)
			in.NotifyEntry(name)
			walk(c)
		}
	}
	walk(&v.root.Inode)
}
