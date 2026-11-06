package main

// The guards the Python never had (found by review after the port), without a mount.

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
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
	v, err := newView(src, append(slices.Clone(guardRules(t)), ParseRules(lines(project), false)...), -1, -1)
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
		{[]string{"d/objects/", "d/refs/", "d/hooks/x"}, "d/README", false},
	} {
		v := scratchView(t, "", c.files...)
		if got := v.plantsGitdir(c.add); got != c.refused {
			t.Errorf("%v + %s: refused=%v, want %v", c.files, c.add, got, c.refused)
		}
	}
}
