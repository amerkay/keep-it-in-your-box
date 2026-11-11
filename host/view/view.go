package main

// The redacting view of the project, shared by both front ends (nfs.go, fuse.go). Redacted paths refuse writes and read as their keys
// (Render) or the stub; protected paths read through and refuse writes, except a nested
// byte-identical copy of the same guarded tail at the ROOT (reproduce, never author). Every
// check and the syscall after it use the same path, and every syscall resolves it beneath --src
// with no symlink on the way (`at`), so nothing swapped in between can redirect it. An
// operation not implemented here is refused by the front end (xattrs, mknod, fallocate).
// Spec: tests/fixtures/redaction/fs.json; history: docs/design-notes/redaction-config-guard.md.

import (
	"bytes"
	"encoding/binary"
	"errors"
	"hash/fnv"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	redactedName = "REDACTED.md"
	refused      = syscall.EPERM // the guard's errno; EACCES stays default_permissions'
	writeFlags   = syscall.O_WRONLY | syscall.O_RDWR | syscall.O_APPEND | syscall.O_CREAT |
		syscall.O_TRUNC
	verdictMax = 1 << 16
	renderKeep = 64
	mirrorMax  = 1 << 26 // a guarded file bigger than this is never a valid mirror
	// renameNoReplace is Linux's RENAME_NOREPLACE, the one rename flag FUSE may pass.
	renameNoReplace = 1
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

// mirrorGrace: NFS has no close, so a mirror is checked once its writes stop this long, or
// 5× that after its first write, so rewriting a short copy cannot keep it alive. A var only so a
// test can shorten it.
var mirrorGrace = 2 * time.Second

type pending struct {
	t     *time.Timer
	first time.Time
}

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
	src        string
	srcfd      int // every syscall resolves beneath it
	rules      atomic.Pointer[ruleSet]
	generation atomic.Uint64 // bumped on reload: no cached page survives a rule change
	renderMu   sync.Mutex
	renders    map[renderKey][]byte
	mirrorMu   sync.Mutex
	mirrors    map[string]*pending
	sillies    []moved // every silly name made, oldest first, removed at exit
}

// moved: a silly name and the path its file was moved aside from.
type moved struct{ alias, orig string }

// dropSillies unlinks every silly name this view made. The client deletes one when its file's
// last fd closes, but at teardown that races the view's exit, and lost: `.nfs` debris in the
// project, shown by git status. Nothing holds them once the box is gone.
func (v *view) dropSillies() {
	v.mirrorMu.Lock()
	defer v.mirrorMu.Unlock()
	for _, m := range v.sillies {
		_ = v.inParent(m.alias, func(dfd int, name string) error { return unix.Unlinkat(dfd, name, 0) })
	}
	v.sillies = nil
}

func newView(src string, rules []Rule) (*view, error) {
	real, err := filepath.EvalSymlinks(src)
	if err != nil {
		return nil, err
	}
	fd, err := unix.Open(real, dirFlags|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	v := &view{src: real, srcfd: fd, renders: map[renderKey][]byte{}, mirrors: map[string]*pending{}}
	v.setRules(rules)
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
	return openBeneath(v.srcfd, rel, flags, mode)
}

// inParent runs fn on rel's directory (opened as `at` does) and base name.
func (v *view) inParent(rel string, fn func(dfd int, name string) error) error {
	dfd, err := v.at(filepath.Dir(rel), dirFlags, 0)
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

func (v *view) lstatAt(rel string) (syscall.Stat_t, error) {
	var st unix.Stat_t
	err := v.inParent(rel, func(dfd int, name string) error {
		return unix.Fstatat(dfd, name, &st, unix.AT_SYMLINK_NOFOLLOW)
	})
	return *(*syscall.Stat_t)(unsafe.Pointer(&st)), err // one struct stat, under two Go names
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

func lowerParts(rel string) []string { return strings.Split(fold(rel), "/") }

func (v *view) isGitdir(rel string) bool {
	for _, m := range gitdirMarkers {
		_, err := os.Stat(filepath.Join(v.real(rel), m))
		if err != nil && v.aliasOf(filepath.Join(rel, m)) == "" {
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
	return rel != "" && (v.verdict(rel) == Protect || v.gitSensitive(rel) || silly(rel))
}

// silly: the NFS client's name for a file still open when it is unlinked or replaced
// (.nfs + 24 hex). Never written: it may alias a guarded file (sillyRename). Unlinkable.
func silly(rel string) bool {
	b := filepath.Base(rel)
	if len(b) != 28 || !strings.HasPrefix(b, ".nfs") {
		return false
	}
	for _, c := range b[4:] {
		if !strings.ContainsRune("0123456789abcdef", c) {
			return false
		}
	}
	return true
}

// aliasOf: the newest live silly name rel was moved aside to, or "". While one lives, rel still
// counts as a git dir marker: else git's HEAD.lock rename reads as planting a git dir.
func (v *view) aliasOf(rel string) string {
	v.mirrorMu.Lock()
	defer v.mirrorMu.Unlock()
	for i := len(v.sillies) - 1; i >= 0; i-- {
		if m := v.sillies[i]; fold(m.orig) == fold(rel) {
			if _, err := v.lstatAt(m.alias); err == nil {
				return m.alias
			}
		}
	}
	return ""
}

// unsilly links rel back from its silly name after a rename onto it failed: else it is lost.
func (v *view) unsilly(rel string) {
	a := v.aliasOf(rel)
	if _, err := v.lstatAt(rel); a == "" || err == nil || v.denyNew(rel, false) != 0 {
		return
	}
	_ = v.inParent(a, func(adfd int, aname string) error {
		return v.inParent(rel, func(dfd int, name string) error {
			return unix.Linkat(adfd, aname, dfd, name, 0)
		})
	})
}

// sillyRename moves an open file aside for the NFS client. A file that may be deleted is
// moved. A git config, which git replaces by renaming config.lock over it, stays put with the
// silly name a read-only alias, so that rename is still checked against it; the box's own
// delete of one then reports success and changes nothing. Any other guarded file is refused.
// Never a redacted file.
func (v *view) sillyRename(old, dst string) syscall.Errno {
	if k, _ := v.classify(old); k != pass {
		return refused
	}
	if k, _ := v.classify(dst); k != pass {
		return refused
	}
	if st, err := v.lstatAt(old); err != nil || st.Mode&unix.S_IFMT == unix.S_IFDIR {
		return refused
	}
	move := v.deny(old, true) == 0 || silly(old) // an alias moves on: still read-only
	if !move && !v.isGitConfig(old) {
		return refused
	}
	orig := old
	v.mirrorMu.Lock()
	for _, m := range v.sillies {
		if m.alias == old {
			orig = m.orig
		}
	}
	v.sillies = append(v.sillies, moved{dst, orig})
	v.mirrorMu.Unlock()
	return toErrno(v.inParent(old, func(odfd int, oname string) error {
		return v.inParent(dst, func(ddfd int, dname string) error {
			if move {
				return renameAt(odfd, oname, ddfd, dname, 0)
			}
			return unix.Linkat(odfd, oname, ddfd, dname, 0)
		})
	}))
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
		(o[0] == ".git") != (d[0] == ".git") { // folded: on macOS `.GIT` is the real .git
		logf("kib-view: refusing to move directory %s to %s (a guard rule spans it)", old, dst)
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
		if fold(m) == fold(base) {
			found = true
		} else if _, err := v.lstatAt(filepath.Join(d, m)); err != nil {
			return false
		}
	}
	if !found {
		return false
	}
	// Replacing a marker (git's HEAD.lock rename) completes nothing: d already was a git dir.
	if _, err := v.lstatAt(rel); err == nil || v.aliasOf(rel) != "" {
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
		logf("kib-view: refusing %s: it makes a git dir of unchecked hooks or config", rel)
		return refused
	}
	return 0
}

// deny refuses a write to a masked path. mirrorOK=false refuses even an exact copy, for the ops
// that move bytes the guard never compared (rename, link, symlink) or reshape one (truncate).
func (v *view) deny(rel string, mirrorOK bool) syscall.Errno {
	if k, _ := v.classify(rel); k != pass {
		logf("kib-view: refusing a write to %s (redacted)", rel)
		return refused
	}
	if v.protected(rel) && !(mirrorOK && v.mirrorable(rel)) {
		logf("kib-view: refusing a write to %s (protected)", rel)
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
	var st syscall.Stat_t
	if syscall.Fstat(fd, &st) != nil {
		return Stub
	}
	key := renderKey{root, st.Ino, uint64(mtime(&st).UnixNano()), st.Size}
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

// toErrno: the errno a front end returns for err.
func toErrno(err error) syscall.Errno {
	var e syscall.Errno
	switch {
	case err == nil:
		return 0
	case errors.As(err, &e):
		return e
	case errors.Is(err, os.ErrNotExist):
		return syscall.ENOENT
	}
	return syscall.EIO
}

// stat is rel as the view shows it, the masked shapes synthesised (timestamped from the masked
// root, so a watcher sees one file change, not the whole tree). Ino is unique per path, kind and
// real inode, so a reload that masks a file makes it a new one to any cache.
func (v *view) stat(rel string) (syscall.Stat_t, syscall.Errno) {
	k, root := v.classify(rel)
	statPath := rel
	if k == file || k == dir || k == inside {
		statPath = root
	}
	// Beneath --src: a handle's path may have had a symlink swapped in since (NFS handles are paths).
	st, err := v.lstatAt(statPath)
	if err != nil {
		return st, toErrno(err)
	}
	switch k {
	case file:
		st.Mode, st.Nlink, st.Size = syscall.S_IFREG|0o444, 1, int64(len(v.render(root)))
	case dir:
		st.Mode, st.Nlink, st.Size = syscall.S_IFDIR|0o555, 2, 0
	case inside:
		if filepath.Base(rel) != redactedName || filepath.Dir(rel) != root {
			return st, syscall.ENOENT
		}
		st.Mode, st.Nlink, st.Size = syscall.S_IFREG|0o444, 1, int64(len(Stub))
	}
	h := fnv.New64a()
	h.Write([]byte(rel))
	h.Write([]byte{0, byte(st.Mode >> 12), byte(k)})
	h.Write(binary.LittleEndian.AppendUint64(nil, st.Ino))
	st.Ino = h.Sum64() | 1<<63
	return st, 0
}

// handle is an open file: a real fd, or a synthesised render (fd -1).
type handle struct {
	fd        int
	data      []byte
	mirroring bool // opened for writing at a protected path: size-checked once written
}

// open: flags as open(2) takes them, less O_CREAT (that is create).
func (v *view) open(rel string, flags int) (*handle, syscall.Errno) {
	k, root := v.classify(rel)
	if flags&writeFlags != 0 {
		// Nothing legitimate writes .git/config in place: git renames config.lock over it.
		if errno := v.deny(rel, true); errno != 0 {
			return nil, errno
		}
	}
	switch k {
	case file:
		return &handle{fd: -1, data: v.render(root)}, 0
	case inside:
		if filepath.Base(rel) != redactedName || filepath.Dir(rel) != root {
			return nil, syscall.ENOENT
		}
		fallthrough
	case dir:
		return &handle{fd: -1, data: Stub}, 0
	}
	fd, err := v.at(rel, flags&^syscall.O_CREAT, 0)
	if err != nil {
		return nil, toErrno(err)
	}
	return &handle{fd: fd, mirroring: flags&writeFlags != 0 && v.protected(rel)}, 0
}

func (v *view) create(rel string, flags int, mode uint32) (*handle, syscall.Errno) {
	if errno := v.denyNew(rel, true); errno != 0 {
		return nil, errno
	}
	fd, err := v.at(rel, flags|syscall.O_CREAT, mode&0o7777)
	if err != nil {
		return nil, toErrno(err)
	}
	return &handle{fd: fd, mirroring: v.protected(rel)}, 0
}

// served is what h reads as now, nil for its fd: one opened before a reload redacted it reads
// as a new open would.
func (v *view) served(rel string, h *handle) []byte {
	if h.fd < 0 {
		return h.data
	}
	switch k, root := v.classify(rel); k {
	case pass:
		return nil
	case file:
		return v.render(root)
	}
	return Stub
}

// write lets a mirror only REPRODUCE: each byte is compared with the anchor's at the same
// offset before it lands, so a payload is refused at its first differing byte.
func (v *view) write(rel string, h *handle, data []byte, off int64) (int, syscall.Errno) {
	if h.fd < 0 {
		return 0, syscall.EBADF
	}
	if k, _ := v.classify(rel); k != pass {
		return 0, refused
	}
	if v.protected(rel) && !bytes.Equal(data, v.anchorBytes(rel, off, len(data))) {
		logf("kib-view: refusing a write to %s (not a copy of its root anchor)", rel)
		return 0, refused
	}
	w, err := syscall.Pwrite(h.fd, data, off)
	return max(w, 0), toErrno(err)
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

// wholeMirror removes a mirror that is not its anchor's bytes: a short copy matches as far as it
// goes, and a sparse one is NULs between them, which sh skips and runs the rest. The unlink is
// the enforcement; the errno is a courtesy.
func (v *view) wholeMirror(rel string, h *handle) syscall.Errno {
	if !h.mirroring || !v.protected(rel) {
		return 0
	}
	if a := v.mirrorAnchor(rel); a != "" {
		got, err1 := v.readAt(rel, mirrorMax)
		want, err2 := v.readAt(a, mirrorMax)
		if err1 == nil && err2 == nil && len(want) < mirrorMax && bytes.Equal(got, want) {
			return 0
		}
	}
	h.mirroring = false
	_ = v.inParent(rel, func(dfd int, name string) error { return unix.Unlinkat(dfd, name, 0) })
	logf("kib-view: removed %s: not a whole copy of its root anchor", rel)
	return refused
}

// mirrorLater runs wholeMirror on rel once its writes stop (mirrorGrace).
func (v *view) mirrorLater(rel string) {
	v.mirrorMu.Lock()
	defer v.mirrorMu.Unlock()
	if p := v.mirrors[rel]; p != nil {
		if time.Since(p.first) < 5*mirrorGrace {
			p.t.Reset(mirrorGrace)
		}
		return
	}
	v.mirrors[rel] = &pending{first: time.Now(), t: time.AfterFunc(mirrorGrace, func() {
		v.mirrorMu.Lock()
		delete(v.mirrors, rel)
		v.mirrorMu.Unlock()
		v.wholeMirror(rel, &handle{mirroring: true})
	})}
}

// settle checks every mirror pending at or under rel ("" is all) now: a move would strand its
// timer at a path that no longer holds it, and the short copy would stay.
func (v *view) settle(rel string) {
	f := fold(rel)
	var due []string
	v.mirrorMu.Lock()
	for p, m := range v.mirrors {
		if fp := fold(p); rel == "" || fp == f || strings.HasPrefix(fp, f+"/") {
			m.t.Stop()
			delete(v.mirrors, p)
			due = append(due, p)
		}
	}
	v.mirrorMu.Unlock()
	for _, p := range due {
		v.wholeMirror(p, &handle{mirroring: true})
	}
}

// truncate through fd, or rel opened for it. No mirror: a standalone truncate can only make a
// short copy. A size that is already so changes nothing (NFS sends one after every create).
func (v *view) truncate(rel string, fd int, size int64) syscall.Errno {
	if st, err := v.lstatAt(rel); err == nil && st.Size == size {
		return 0
	}
	if errno := v.deny(rel, false); errno != 0 {
		return errno
	}
	if fd < 0 {
		var err error
		if fd, err = v.at(rel, unix.O_WRONLY|unix.O_NONBLOCK, 0); err != nil {
			return toErrno(err)
		}
		defer unix.Close(fd)
	}
	return toErrno(unix.Ftruncate(fd, size))
}

func (v *view) chmod(rel string, mode uint32) syscall.Errno {
	if errno := v.deny(rel, true); errno != 0 {
		return errno
	}
	return toErrno(v.chmodAt(rel, mode&0o7777))
}

// chown: -1 keeps that half.
func (v *view) chown(rel string, uid, gid int) syscall.Errno {
	if errno := v.deny(rel, true); errno != 0 {
		return errno
	}
	return toErrno(v.inParent(rel, func(dfd int, name string) error {
		return unix.Fchownat(dfd, name, uid, gid, unix.AT_SYMLINK_NOFOLLOW)
	}))
}

// utimes: nil keeps that time.
func (v *view) utimes(rel string, atime, mtime *time.Time) syscall.Errno {
	if errno := v.deny(rel, true); errno != 0 {
		return errno
	}
	ts := []unix.Timespec{{Nsec: utimeOmit}, {Nsec: utimeOmit}}
	for i, t := range []*time.Time{atime, mtime} {
		if t != nil {
			ts[i] = unix.NsecToTimespec(t.UnixNano())
		}
	}
	return toErrno(v.inParent(rel, func(dfd int, name string) error {
		return unix.UtimesNanoAt(dfd, name, ts, unix.AT_SYMLINK_NOFOLLOW)
	}))
}

func (v *view) unlink(rel string) syscall.Errno {
	if errno := v.deny(rel, true); errno != 0 && !silly(rel) {
		return errno
	}
	return toErrno(v.inParent(rel, func(dfd int, name string) error {
		return unix.Unlinkat(dfd, name, 0)
	}))
}

func (v *view) rmdir(rel string) syscall.Errno {
	if errno := v.deny(rel, true); errno != 0 {
		return errno
	}
	return toErrno(v.inParent(rel, func(dfd int, name string) error {
		return unix.Unlinkat(dfd, name, unix.AT_REMOVEDIR)
	}))
}

func (v *view) mkdir(rel string, mode uint32) syscall.Errno {
	if errno := v.denyNew(rel, true); errno != 0 {
		return errno
	}
	return toErrno(v.inParent(rel, func(dfd int, name string) error {
		return unix.Mkdirat(dfd, name, mode)
	}))
}

// rename moves bytes the guard never compared, so neither end may be a mirror, and a directory
// may not carry files across a rule (denyDirMove). The one validated write: git's config.lock
// renamed over a config, checked for new command keys.
func (v *view) rename(old, dst string, flags uint32) syscall.Errno {
	errno := v.renameChecked(old, dst, flags)
	if errno != 0 {
		v.unsilly(dst)
	}
	return errno
}

func (v *view) renameChecked(old, dst string, flags uint32) syscall.Errno {
	if flags&^renameNoReplace != 0 {
		return syscall.EINVAL // an exchange would move the target too, unchecked
	}
	if silly(dst) && filepath.Dir(dst) == filepath.Dir(old) {
		return v.sillyRename(old, dst)
	}
	if errno := v.deny(old, false); errno != 0 {
		return errno
	}
	if st, err := v.lstatAt(old); err == nil && st.Mode&unix.S_IFMT == unix.S_IFDIR {
		if errno := v.denyDirMove(old, dst); errno != 0 {
			return errno
		}
	}
	if k, _ := v.classify(dst); k == pass && v.isGitConfig(dst) {
		cand, err := v.readAt(old, 1<<20)
		cur, curErr := v.readAt(dst, 1<<20)
		if err != nil || !gitConfigWriteOK(cand, cur, curErr) {
			return refused
		}
	} else if errno := v.denyNew(dst, false); errno != 0 {
		return errno
	}
	v.settle(old)
	return toErrno(v.inParent(old, func(odfd int, oname string) error {
		return v.inParent(dst, func(ddfd int, dname string) error {
			return renameAt(odfd, oname, ddfd, dname, uint(flags))
		})
	}))
}

// link checks the SOURCE too: a hardlink is a second name for the same inode, so an unguarded
// alias would launder a guarded file past every path check.
func (v *view) link(src, rel string) syscall.Errno {
	if errno := v.denyNew(rel, false); errno != 0 {
		return errno
	}
	if errno := v.deny(src, false); errno != 0 {
		return errno
	}
	return toErrno(v.inParent(src, func(sdfd int, sname string) error {
		return v.inParent(rel, func(dfd int, dname string) error {
			return unix.Linkat(sdfd, sname, dfd, dname, 0)
		})
	}))
}

// symlink: a link's content is a path, never the anchor's bytes, so no mirror.
func (v *view) symlink(target, rel string) syscall.Errno {
	if errno := v.denyNew(rel, false); errno != 0 {
		return errno
	}
	return toErrno(v.inParent(rel, func(dfd int, name string) error {
		return unix.Symlinkat(target, dfd, name)
	}))
}

func (v *view) readlink(rel string) (string, syscall.Errno) {
	if k, _ := v.classify(rel); k != pass {
		return "", refused
	}
	buf := make([]byte, 4096)
	var got int
	err := v.inParent(rel, func(dfd int, name string) (err error) {
		got, err = unix.Readlinkat(dfd, name, buf)
		return err
	})
	if err != nil {
		return "", toErrno(err)
	}
	return string(buf[:got]), 0
}

type dirent struct {
	name string
	mode uint32 // S_IFDIR, S_IFLNK or S_IFREG
}

// list reads the directory now, sorted, without . and ..
func (v *view) list(rel string) ([]dirent, syscall.Errno) {
	switch k, _ := v.classify(rel); k {
	case dir:
		return []dirent{{redactedName, syscall.S_IFREG}}, 0
	case file, inside:
		return nil, 0
	}
	fd, err := v.at(rel, unix.O_RDONLY|unix.O_DIRECTORY, 0)
	if err != nil {
		return nil, toErrno(err)
	}
	d := os.NewFile(uintptr(fd), rel)
	ents, err := d.ReadDir(-1)
	d.Close()
	if err != nil {
		return nil, toErrno(err)
	}
	var out []dirent
	for _, e := range ents {
		mode := uint32(syscall.S_IFREG)
		if e.IsDir() {
			mode = syscall.S_IFDIR
		} else if e.Type()&os.ModeSymlink != 0 {
			mode = syscall.S_IFLNK
		}
		out = append(out, dirent{e.Name(), mode})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].name < out[j].name })
	return out, 0
}
