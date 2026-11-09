package main

// The guards the Python never had (found by review after the port), without a mount.

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

func scratchView(t *testing.T, project string, files ...string) *view {
	t.Helper()
	src := t.TempDir()
	for _, f := range files {
		full := filepath.Join(src, f)
		if f[len(f)-1] == '/' {
			os.MkdirAll(full, 0o755)
			continue
		}
		os.MkdirAll(filepath.Dir(full), 0o755)
		os.WriteFile(full, []byte("[core]\n\tfsmonitor = x\n"), 0o644)
	}
	v, err := newView(src, append(slices.Clone(guardRules(t)), ParseRules(lines(project), false)...))
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestDirMoves(t *testing.T) {
	v := scratchView(t, "secrets/key.pem\n!certs/pub.pem\n*.pem", "store/HEAD", "store/objects/", "store/refs/", "src/")
	for _, c := range []struct {
		old, dst string
		refused  bool
	}{
		{"secrets", "s2", true},      // would carry key.pem out of its rule
		{"x", "secrets", true},       // into it
		{"x", "certs", true},         // onto a negation's path
		{"x", "a/.zed", true},        // would author .zed/tasks.json (guard, any depth)
		{".zed", "x", true},          // the other way
		{".git", "old", true},        // the host's git dir
		{"fake", ".git", true},       // a replacement for it
		{"fake", "a/.GIT", true},     // folded
		{"keys", ".GIT/keys", true},  // into .git on macOS, where bare rules stop
		{"store", "x", true},         // a git dir by its layout
		{"keys", ".git/keys", true},  // bare rules (*.pem) stop inside .git
		{".git/x", "x", true},        // and start outside it
		{"a/secrets", "a/s2", false}, // secrets/key.pem is anchored at the root
		{"src", "lib", false},        // ordinary
		{"a/node_modules", "b/node_modules", false},
	} {
		if got := v.denyDirMove(c.old, c.dst) != 0; got != c.refused {
			t.Errorf("move %s -> %s: refused=%v, want %v", c.old, c.dst, got, c.refused)
		}
	}
}

func TestPlantsGitdir(t *testing.T) {
	for _, c := range []struct {
		files   []string
		add     string
		refused bool
	}{
		{[]string{"d/objects/", "d/refs/", "d/hooks/pre-commit"}, "d/HEAD", true},
		{[]string{"d/HEAD", "d/refs/", "d/config"}, "d/objects", true},   // config names fsmonitor
		{[]string{"d/HEAD", "d/refs/", "d/hooks/"}, "d/objects", false},  // git init --bare
		{[]string{"d/objects/", "d/hooks/x"}, "d/HEAD", false},           // refs still missing
		{[]string{"d/objects/", "d/refs/", "d/hooks/x"}, "d/head", true}, // folded
		{[]string{"d/HEAD", "d/refs/", "d/hooks/x"}, "d/objecſ", false},  // not a marker
		{[]string{"d/HEAD", "d/refs/", "d/hooks/x"}, "d/objectſ", true},  // APFS's objects
		{[]string{"d/objects/", "d/refs/", "d/hooks/x"}, "d/README", false},
		{[]string{"d/HEAD", "d/objects/", "d/refs/", "d/hooks/x"}, "d/HEAD", false}, // git switch
	} {
		v := scratchView(t, "", c.files...)
		if got := v.plantsGitdir(c.add); got != c.refused {
			t.Errorf("%v + %s: refused=%v, want %v", c.files, c.add, got, c.refused)
		}
	}
}

// The NFS client moves an open file aside before replacing or deleting it. A guarded file stays,
// aliased read-only; a mirror moves; a redacted file never does.
func TestSillyRename(t *testing.T) {
	v := scratchView(t, "", ".git/HEAD", ".git/objects/", ".git/refs/", ".git/config",
		".vscode/settings.json", "w/.vscode/settings.json", ".env")
	src := v.src
	const s = ".nfs0123456789abcdef01234567"
	if e := v.rename(".git/config", ".git/"+s, 0); e != 0 {
		t.Fatalf("silly rename of .git/config: %v", e)
	}
	if !lexists(filepath.Join(src, ".git/config")) || !lexists(filepath.Join(src, ".git", s)) {
		t.Error(".git/config must stay, with the silly name beside it")
	}
	if _, e := v.open(".git/"+s, os.O_WRONLY); e == 0 {
		t.Error("the silly alias of .git/config opened for writing")
	}
	// The alias is open in gVisor too, so deleting it is a second silly rename: it moves on.
	if e := v.rename(".git/"+s, ".git/.nfs0123456789abcdef0123456f", 0); e != 0 {
		t.Errorf("an open alias could not be moved on for its delete: %v", e)
	}
	if e := v.unlink(".git/.nfs0123456789abcdef0123456f"); e != 0 {
		t.Errorf("the silly name could not be unlinked: %v", e)
	}
	if e := v.rename("w/.vscode/settings.json", "w/.vscode/"+s, 0); e != 0 ||
		lexists(filepath.Join(src, "w/.vscode/settings.json")) {
		t.Errorf("a mirror was not moved aside: %v", e)
	}
	v.dropSillies()
	if lexists(filepath.Join(src, "w/.vscode", s)) {
		t.Error("a moved-aside file outlived the view: .nfs debris in the project")
	}
	if e := v.rename(".vscode/settings.json", ".vscode/"+s, 0); e == 0 {
		t.Error("a root anchor was moved aside")
	}
	v.dropSillies()
	if e := v.rename(".git/config", ".git/"+s, 0); e != 0 {
		t.Fatal(e)
	}
	v.dropSillies()
	if lexists(filepath.Join(src, ".git", s)) || !lexists(filepath.Join(src, ".git/config")) {
		t.Error("the alias outlived the view, or took the config with it")
	}
	if e := v.rename(".env", s, 0); e == 0 {
		t.Error("a redacted file was moved aside")
	}
	if _, e := v.create(".git/"+s, os.O_WRONLY, 0o644); e == 0 {
		t.Error("the box created a silly name")
	}
}

// git config over NFS: the client moves the open config aside, then renames config.lock over it.
// The rename must still be checked against the config kept in place: benign passes, a command
// key does not, and the config survives the refusal. (Every `git config` write took this path.)
func TestGitConfigWriteAfterSillyRename(t *testing.T) {
	v := scratchView(t, "", ".git/HEAD", ".git/objects/", ".git/refs/", ".git/config")
	cfg := filepath.Join(v.src, ".git/config")
	orig, _ := os.ReadFile(cfg)
	put := func(text string) {
		h, e := v.create(".git/config.lock", os.O_WRONLY|os.O_TRUNC, 0o644)
		if e != 0 {
			t.Fatalf("config.lock: %v", e)
		}
		v.write(".git/config.lock", h, []byte(text), 0)
		unix.Close(h.fd)
	}
	silly := func(n string) {
		if e := v.rename(".git/config", ".git/.nfs0123456789abcdef0123456"+n, 0); e != 0 {
			t.Fatalf("silly rename: %v", e)
		}
	}
	silly("7")
	put(string(orig) + "[user]\n\tname = x\n")
	if e := v.rename(".git/config.lock", ".git/config", 0); e != 0 {
		t.Errorf("a benign config write was refused: %v", e)
	}
	silly("8")
	put("[core]\n\tfsmonitor = /tmp/evil\n")
	if e := v.rename(".git/config.lock", ".git/config", 0); e == 0 {
		t.Error("a config write that changes core.fsmonitor was accepted")
	}
	if b, _ := os.ReadFile(cfg); !strings.Contains(string(b), "name = x") {
		t.Errorf("the config did not survive: %q", b)
	}
}

// APFS opens a look-alike as the real file, so git's own paths are matched folded too.
func TestGitPathsFolded(t *testing.T) {
	v := scratchView(t, "")
	for _, p := range []string{".git/hookſ/pre-commit", ".GIT/config", ".git/conﬁg"} {
		if !v.protected(p) {
			t.Errorf("%s is not protected", p)
		}
	}
}

// NFS handles are paths: a symlink swapped in under one must not lead stat out of the project.
func TestStatStaysBeneath(t *testing.T) {
	v := scratchView(t, "")
	os.Symlink("/", filepath.Join(v.src, "a"))
	if _, e := v.stat("a/etc"); e == 0 {
		t.Error("stat followed a symlink out of the project")
	}
}
