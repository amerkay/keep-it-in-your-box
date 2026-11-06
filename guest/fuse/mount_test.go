package main

// tests/fixtures/redaction/fs.json on a real mount. Needs /dev/fuse (and fusermount3 unless
// root): skipped without it, unless KIB_FUSE_TESTS=1 (CI) makes that a failure.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"

	"github.com/hanwen/go-fuse/v2/fs"
)

type fsCase struct {
	Name, Project string
	Tree          map[string]string
	Drop          []string
	Steps         []map[string]any
	After         map[string]string
}

func errName(err error) string {
	var e syscall.Errno
	if errors.As(err, &e) {
		for _, n := range []syscall.Errno{syscall.EPERM, syscall.ENOENT, syscall.EACCES,
			syscall.EEXIST, syscall.ENOTDIR, syscall.EISDIR, syscall.EINVAL,
			syscall.ENOTEMPTY, syscall.EXDEV, syscall.EBADF, syscall.ELOOP} {
			if e == n {
				return map[syscall.Errno]string{syscall.EPERM: "EPERM", syscall.ENOENT: "ENOENT",
					syscall.EACCES: "EACCES", syscall.EEXIST: "EEXIST", syscall.ENOTDIR: "ENOTDIR",
					syscall.EISDIR: "EISDIR", syscall.EINVAL: "EINVAL", syscall.ENOTEMPTY: "ENOTEMPTY",
					syscall.EXDEV: "EXDEV", syscall.EBADF: "EBADF", syscall.ELOOP: "ELOOP"}[n]
			}
		}
	}
	return err.Error()
}

func step(mnt, src string, s map[string]any) any {
	path := s["path"].(string)
	p := filepath.Join(mnt, path)
	if parent := filepath.Dir(filepath.Join(src, path)); !lexists(parent) {
		_ = os.MkdirAll(parent, 0o755)
	}
	to, _ := s["to"].(string)
	or := func(err error, phase string) any {
		if err == nil {
			return "OK"
		}
		if phase != "" {
			return errName(err) + "@" + phase
		}
		return errName(err)
	}
	switch s["op"] {
	case "put":
		data := []byte("x\n")
		if d, ok := s["data"].(string); ok {
			data = []byte(d)
		}
		if h, ok := s["hex"].(string); ok {
			fmt.Sscanf(h, "%x", &data)
		}
		f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
		if err != nil {
			return or(err, "open")
		}
		var werr error
		if len(data) > 0 {
			_, werr = f.Write(data)
		}
		cerr := f.Close()
		if werr != nil {
			return or(werr, "write")
		}
		return or(cerr, "close")
	case "open-r", "open-w":
		flag := os.O_RDONLY
		if s["op"] == "open-w" {
			flag = os.O_WRONLY
		}
		f, err := os.OpenFile(p, flag, 0)
		if err == nil {
			f.Close()
		}
		return or(err, "")
	case "read":
		b, err := os.ReadFile(p)
		if err != nil {
			return or(err, "")
		}
		if string(b) == string(Stub) {
			return "STUB"
		}
		return string(b)
	case "stat":
		st, err := os.Lstat(p)
		if err != nil {
			return or(err, "")
		}
		typ, size := "file", any(st.Size())
		if st.IsDir() {
			typ, size = "dir", nil
		} else if st.Mode()&os.ModeSymlink != 0 {
			typ, size = "symlink", nil
		}
		return map[string]any{"type": typ, "perm": fmt.Sprintf("0o%o", st.Mode().Perm()), "size": size}
	case "readdir":
		ents, err := os.ReadDir(p)
		if err != nil {
			return or(err, "")
		}
		names := []any{}
		for _, e := range ents {
			names = append(names, e.Name())
		}
		return names
	case "unlink":
		return or(syscall.Unlink(p), "")
	case "rmdir":
		return or(syscall.Rmdir(p), "")
	case "mkdir":
		return or(syscall.Mkdir(p, 0o755), "")
	case "rename":
		return or(os.Rename(p, filepath.Join(mnt, to)), "")
	case "link":
		return or(os.Link(filepath.Join(mnt, to), p), "")
	case "symlink":
		return or(os.Symlink(to, p), "")
	case "truncate":
		return or(os.Truncate(p, int64(s["length"].(float64))), "")
	}
	return "unknown op"
}

func snapshot(src string) map[string]string {
	out := map[string]string{}
	filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		rel, _ := filepath.Rel(src, p)
		switch {
		case err != nil || rel == ".":
		case info.Mode()&os.ModeSymlink != 0:
			t, _ := os.Readlink(p)
			out[rel] = "-> " + t
		case info.IsDir():
			out[rel+"/"] = ""
		default:
			b, _ := os.ReadFile(p)
			if s := string(b); strings.ToValidUTF8(s, "�") == s {
				out[rel] = s
			} else {
				out[rel] = "hex:" + fmt.Sprintf("%x", b)
			}
		}
		return nil
	})
	return out
}

func mount(t *testing.T, src string, rules []Rule) string {
	t.Helper()
	mnt := t.TempDir()
	v, err := newView(src, rules, -1, -1)
	if err != nil {
		t.Fatal(err)
	}
	opts := mountOptions(false)
	opts.DirectMount = true // as root (a container); go-fuse falls back to fusermount3
	server, err := fs.Mount(mnt, v.root, opts)
	if err != nil {
		if os.Getenv("KIB_FUSE_TESTS") == "1" {
			t.Fatalf("mount: %v", err)
		}
		t.Skipf("no FUSE here: %v", err)
	}
	t.Cleanup(func() { _ = server.Unmount() })
	return mnt
}

func TestMount(t *testing.T) {
	var cases []fsCase
	readJSON(t, "fs.json", &cases)
	if len(cases) < 30 {
		t.Fatal("fs.json did not load")
	}
	guard := guardRules(t)
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			src := t.TempDir()
			for rel, text := range c.Tree {
				full := filepath.Join(src, rel)
				if strings.HasSuffix(rel, "/") {
					os.MkdirAll(full, 0o755)
					continue
				}
				os.MkdirAll(filepath.Dir(full), 0o755)
				os.WriteFile(full, []byte(text), 0o644)
			}
			for _, rel := range c.Drop {
				os.Remove(filepath.Join(src, rel))
			}
			mnt := mount(t, src, append(slices.Clone(guard), ParseRules(lines(c.Project), false)...))
			for _, s := range c.Steps {
				got, want := fmt.Sprint(step(mnt, src, s)), fmt.Sprint(s["want"])
				if got != want && !kernelRefused(got, want) {
					t.Errorf("%s %s: got %s, want %s", s["op"], s["path"], got, want)
				}
			}
			if got := snapshot(src); !mapsEqual(got, c.After) {
				t.Errorf("tree after:\n got %v\nwant %v", got, c.After)
			}
		})
	}
}

func mapsEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if w, ok := b[k]; !ok || w != v {
			return false
		}
	}
	return true
}

// kernelRefused: the recorder called the view directly, but on a mount the kernel may refuse
// first — a lookup inside a redacted directory says ENOENT, and default_permissions says
// EACCES for a 0444 stub or 0555 marker directory. The tree after is checked either way.
func kernelRefused(got, want string) bool {
	g, gp, _ := strings.Cut(got, "@")
	w, wp, _ := strings.Cut(want, "@")
	return w == "EPERM" && gp == wp && (g == "ENOENT" || g == "EACCES")
}

// A file opened before a reload redacted it reads as a new open would (the Python re-checked
// every read); and no write lands through a symlink swapped in after the check.
func TestReloadAndSymlinkSwap(t *testing.T) {
	src := t.TempDir()
	os.WriteFile(filepath.Join(src, "notes.txt"), []byte("K=s3cr3t\n"), 0o644)
	os.MkdirAll(filepath.Join(src, ".git", "hooks"), 0o755)
	os.MkdirAll(filepath.Join(src, "d"), 0o755)
	guard := guardRules(t)
	v, err := newView(src, guard, -1, -1)
	if err != nil {
		t.Fatal(err)
	}
	opts := mountOptions(false)
	opts.DirectMount = true
	mnt := t.TempDir()
	server, err := fs.Mount(mnt, v.root, opts)
	if err != nil {
		if os.Getenv("KIB_FUSE_TESTS") == "1" {
			t.Fatalf("mount: %v", err)
		}
		t.Skipf("no FUSE here: %v", err)
	}
	t.Cleanup(func() { _ = server.Unmount() })

	f, err := os.Open(filepath.Join(mnt, "notes.txt"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	v.reload(append(slices.Clone(guard), ParseRules([]string{"notes.txt"}, false)...))
	buf := make([]byte, 64)
	n, _ := f.ReadAt(buf, 0)
	if strings.Contains(string(buf[:n]), "s3cr3t") {
		t.Errorf("an open file still reads its value after a reload redacted it: %q", buf[:n])
	}

	// d is checked as an ordinary directory; the host swaps it for a link into .git/hooks.
	os.WriteFile(filepath.Join(mnt, "payload"), []byte("#!/bin/sh\n"), 0o755)
	if _, err := os.Stat(filepath.Join(mnt, "d")); err != nil {
		t.Fatal(err)
	}
	os.Remove(filepath.Join(src, "d"))
	os.Symlink(".git/hooks", filepath.Join(src, "d"))
	_ = os.Rename(filepath.Join(mnt, "payload"), filepath.Join(mnt, "d", "pre-commit"))
	if _, err := os.Lstat(filepath.Join(src, ".git", "hooks", "pre-commit")); err == nil {
		t.Error("a rename landed in .git/hooks through a swapped-in symlink")
	}
}
