package main

// tests/fixtures/redaction/fs.json: the cases and the tree they leave, for each front end.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
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

// forEachCase builds each case's tree, runs it, then checks the tree it left.
func forEachCase(t *testing.T, run func(t *testing.T, c fsCase, src string, rules []Rule)) {
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
			run(t, c, src, append(slices.Clone(guard), ParseRules(lines(c.Project), false)...))
			if got := snapshot(src); !mapsEqual(got, c.After) {
				t.Errorf("tree after:\n got %v\nwant %v", got, c.After)
			}
		})
	}
}

// result is what the recorder wrote for err: OK, or the errno's name, @phase if given.
func result(err error, phase string) any {
	if err == nil {
		return "OK"
	}
	if phase != "" {
		return errName(err) + "@" + phase
	}
	return errName(err)
}

func statResult(st os.FileInfo) any {
	typ, size := "file", any(st.Size())
	if st.IsDir() {
		typ, size = "dir", nil
	} else if st.Mode()&os.ModeSymlink != 0 {
		typ, size = "symlink", nil
	}
	return map[string]any{"type": typ, "perm": fmt.Sprintf("0o%o", st.Mode().Perm()), "size": size}
}
