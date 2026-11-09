package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	nfs "github.com/willscott/go-nfs"
	nfsc "github.com/willscott/go-nfs-client/nfs"
	"github.com/willscott/go-nfs-client/nfs/rpc"
)

// nfsStep is the recorder's op as go-nfs makes it: a create opens O_CREAT|O_TRUNC, a truncate
// opens O_EXCL then truncates, and a link (which go-nfs cannot serve) is the core's.
func nfsStep(f *nfsFS, src string, s map[string]any) any {
	p := s["path"].(string)
	if parent := filepath.Dir(filepath.Join(src, p)); !lexists(parent) {
		_ = os.MkdirAll(parent, 0o755)
	}
	to, _ := s["to"].(string)
	switch s["op"] {
	case "put":
		data := []byte("x\n")
		if d, ok := s["data"].(string); ok {
			data = []byte(d)
		}
		if h, ok := s["hex"].(string); ok {
			fmt.Sscanf(h, "%x", &data)
		}
		fh, err := f.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
		if err != nil {
			return result(err, "open")
		}
		var werr error
		if at, ok := s["at"].(float64); ok { // a sparse write: holes before it
			fh.Seek(int64(at), io.SeekStart)
		}
		if len(data) > 0 {
			_, werr = fh.Write(data)
		}
		fh.Close()
		return result(werr, "write")
	case "open-r", "open-w":
		if _, err := f.Lstat(p); err != nil { // the client's LOOKUP comes first
			return result(err, "")
		}
		flag := os.O_RDONLY
		if s["op"] == "open-w" {
			flag = os.O_WRONLY
		}
		fh, err := f.OpenFile(p, flag, 0)
		if err == nil {
			fh.Close()
		}
		return result(err, "")
	case "read":
		fh, err := f.Open(resolve(f, p))
		if err != nil {
			return result(err, "")
		}
		defer fh.Close()
		b, err := io.ReadAll(fh)
		if err != nil {
			return result(err, "")
		}
		if string(b) == string(Stub) {
			return "STUB"
		}
		return string(b)
	case "stat":
		st, err := f.Lstat(p)
		if err != nil {
			return result(err, "")
		}
		return statResult(st)
	case "readdir":
		ents, err := f.ReadDir(p)
		if err != nil {
			return result(err, "")
		}
		names := []any{}
		for _, e := range ents {
			names = append(names, e.Name())
		}
		return names
	case "unlink", "rmdir":
		return result(f.Remove(p), "")
	case "mkdir":
		return result(f.MkdirAll(p, 0o755), "")
	case "rename":
		return result(f.Rename(p, to), "")
	case "link":
		return result(pathErr("link", p, f.v.link(clean(to), clean(p))), "")
	case "symlink":
		return result(f.Symlink(to, p), "")
	case "truncate":
		fh, err := f.OpenFile(p, os.O_WRONLY|os.O_EXCL, 0)
		if err != nil {
			return result(err, "")
		}
		defer fh.Close()
		return result(fh.Truncate(int64(s["length"].(float64))), "")
	}
	return "unknown op"
}

// resolve follows symlinks as the NFS client does, a component at a time with READLINK.
func resolve(f *nfsFS, p string) string {
	parts := strings.Split(clean(p), "/")
	for i, hops := 0, 0; i < len(parts) && hops < 8; i++ {
		cur := strings.Join(parts[:i+1], "/")
		st, err := f.Lstat(cur)
		if err != nil || st.Mode()&os.ModeSymlink == 0 {
			continue
		}
		target, _ := f.Readlink(cur)
		parts = append(strings.Split(clean(filepath.Join(filepath.Dir(cur), target)), "/"), parts[i+1:]...)
		i, hops = -1, hops+1
	}
	return strings.Join(parts, "/")
}

func TestNFSSpec(t *testing.T) {
	forEachCase(t, func(t *testing.T, c fsCase, src string, rules []Rule) {
		v, err := newView(src, rules)
		if err != nil {
			t.Fatal(err)
		}
		f := &nfsFS{v: v}
		for _, s := range c.Steps {
			got, want := fmt.Sprint(nfsStep(f, src, s)), fmt.Sprint(s["want"])
			// NFS has no close: a short mirror is removed once its writes stop.
			if got != want && !(want == "EPERM@close" && got == "OK") {
				t.Errorf("%s %s: got %s, want %s", s["op"], s["path"], got, want)
			}
		}
		v.settle("")
	})
}

// git writes its objects 0444, then over NFS each WRITE reopens the file.
func TestNFSOwnerWritesReadOnly(t *testing.T) {
	src := t.TempDir()
	v, _ := newView(src, guardRules(t))
	f := &nfsFS{v: v}
	fh, err := f.OpenFile("obj", os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o444)
	if err != nil {
		t.Fatal(err)
	}
	fh.Close()
	fh, err = f.OpenFile("obj", os.O_RDWR, 0)
	if err != nil {
		t.Fatalf("the owner could not reopen its own 0444 file: %v", err)
	}
	fh.Write([]byte("blob"))
	fh.Close()
	st, _ := os.Stat(filepath.Join(src, "obj"))
	if b, _ := os.ReadFile(filepath.Join(src, "obj")); string(b) != "blob" || st.Mode().Perm() != 0o444 {
		t.Errorf("got %q mode %o, want blob at 0444", b, st.Mode().Perm())
	}
}

// Over the wire: only the secret path mounts, and only once; the mount serves the view.
func TestNFSMount(t *testing.T) {
	src := t.TempDir()
	os.WriteFile(filepath.Join(src, ".env"), []byte("K=s3cr3t\n"), 0o644)
	v, _ := newView(src, guardRules(t))
	h := newHandler(v)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	go nfs.Serve(l, h)
	mount := func(path string) (*nfsc.Target, error) {
		c, err := rpc.DialTCP("tcp", l.Addr().String(), false)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		m := nfsc.Mount{Client: c}
		return m.Mount(path, rpc.AuthNull)
	}
	for _, p := range []string{"/", "", "/" + strings.ToUpper(h.secret)} {
		if _, err := mount(p); err == nil {
			t.Fatalf("mounted %q without the secret", p)
		}
	}
	target, err := mount("/" + h.secret)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := mount("/" + h.secret); err == nil {
		t.Error("a second mount of the secret path was served")
	}
	r, err := target.Open("/.env")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(r)
	r.Close()
	if string(b) != "K=<redacted>\n" {
		t.Errorf(".env over NFS read %q", b)
	}
	if w, err := target.OpenFile("/.env", 0o644); err == nil {
		if _, err := w.Write([]byte("K=planted\n")); err == nil {
			t.Error("a write to .env over NFS was accepted")
		}
		w.Close()
	}
	if got, _ := os.ReadFile(filepath.Join(src, ".env")); string(got) != "K=s3cr3t\n" {
		t.Errorf(".env on the host is now %q", got)
	}
	if _, _, err := h.FromHandle(make([]byte, 16)); err == nil {
		t.Error("a guessed handle resolved")
	}
}

// NFS has no close, so a short copy of a guarded file is removed once its writes stop; a whole one
// stays. A regression here leaves a truncated script where the host runs it.
func TestNFSShortMirrorRemoved(t *testing.T) {
	defer func(g time.Duration) { mirrorGrace = g }(mirrorGrace)
	mirrorGrace = 50 * time.Millisecond
	src := t.TempDir()
	anchor := []byte("{\"a\": 1, \"b\": 2}\n")
	os.MkdirAll(filepath.Join(src, ".vscode"), 0o755)
	os.MkdirAll(filepath.Join(src, "wt/.vscode"), 0o755)
	os.WriteFile(filepath.Join(src, ".vscode/settings.json"), anchor, 0o644)
	v, _ := newView(src, guardRules(t))
	f := &nfsFS{v: v}
	for _, c := range []struct {
		name string
		data []byte
		kept bool
	}{{"short.json", anchor[:5], false}, {"settings.json", anchor, true}} {
		rel := "wt/.vscode/" + c.name
		if c.name == "short.json" { // a short copy at the mirrored name
			rel = "wt/.vscode/settings.json"
		}
		fh, err := f.OpenFile(rel, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o644)
		if err != nil {
			t.Fatal(err)
		}
		fh.Write(c.data)
		fh.Close()
		time.Sleep(4 * mirrorGrace)
		if got := lexists(filepath.Join(src, rel)); got != c.kept {
			t.Errorf("%d bytes of a %d-byte anchor: kept=%v, want %v", len(c.data), len(anchor), got, c.kept)
		}
	}
}

// A short copy may not outlive its check: not by moving its directory before the timer fires
// (the timer is keyed by path), nor by rewriting it to keep resetting the timer.
func TestNFSShortMirrorCannotEscape(t *testing.T) {
	defer func(g time.Duration) { mirrorGrace = g }(mirrorGrace)
	mirrorGrace = 50 * time.Millisecond
	for _, escape := range []string{"move", "rewrite"} {
		src := t.TempDir()
		os.MkdirAll(filepath.Join(src, ".vscode"), 0o755)
		os.MkdirAll(filepath.Join(src, "wt/.vscode"), 0o755)
		os.WriteFile(filepath.Join(src, ".vscode/settings.json"), []byte("{\"a\": 1}\n"), 0o644)
		v, _ := newView(src, guardRules(t))
		f := &nfsFS{v: v}
		put := func(flag int) { // a rewrite is an NFS WRITE: it never creates
			if fh, err := f.OpenFile("wt/.vscode/settings.json", flag, 0o644); err == nil {
				fh.Write([]byte("{"))
				fh.Close()
			}
		}
		put(os.O_RDWR | os.O_CREATE)
		left := "wt2/.vscode/settings.json"
		if escape == "move" {
			if err := f.Rename("wt", "wt2"); err != nil {
				t.Fatal(err)
			}
		} else {
			left = "wt/.vscode/settings.json"
			for end := time.Now().Add(8 * mirrorGrace); time.Now().Before(end); {
				put(os.O_RDWR)
				time.Sleep(mirrorGrace / 2)
			}
		}
		if lexists(filepath.Join(src, left)) {
			t.Errorf("%s: the short copy survived at %s", escape, left)
		}
	}
}
