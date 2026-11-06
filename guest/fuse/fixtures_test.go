package main

// The Python view's recorded behaviour (tests/fixtures/redaction), checked without a mount.
// A fixture's "note" marks where Go is meant to differ: stricter, never looser.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

const fixtures = "../../tests/fixtures/redaction"

func readJSON(t *testing.T, name string, v any) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(fixtures, name))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatal(err)
	}
}

func guardRules(t *testing.T) []Rule {
	r, err := LoadRules("../policy/global.kibignore", true)
	if err != nil || len(r) == 0 {
		t.Fatalf("guard file: %v", err)
	}
	return r
}

func lines(s string) []string { return strings.Split(s, "\n") }

func TestRules(t *testing.T) {
	var f struct {
		Verdict []struct {
			Project, Path, Note string
			Guard               bool
			Want                *string
		}
		Optouts []struct {
			Project, Note string
			Want          []string
		}
		Tightens []struct {
			Old, New string
			Want     bool
		}
	}
	readJSON(t, "rules.json", &f)
	if len(f.Verdict) < 90 || len(f.Optouts) == 0 || len(f.Tightens) == 0 {
		t.Fatal("rules.json did not load")
	}
	guard := guardRules(t)
	for _, c := range f.Verdict {
		rules := ParseRules(lines(c.Project), false)
		if c.Guard {
			rules = append(slices.Clone(guard), rules...)
		}
		got, want := Verdict(rules, c.Path), ""
		if c.Want != nil {
			want = *c.Want
		}
		if c.Note != "" { // case folding: what the lower-cased path gets
			want = Verdict(rules, strings.ToLower(c.Path))
			if want == "" {
				t.Errorf("%q under %q: a case note on a path no rule covers", c.Path, c.Project)
			}
		}
		if got != want {
			t.Errorf("verdict(%q) under %q = %q, want %q", c.Path, c.Project, got, want)
		}
	}
	for _, c := range f.Optouts {
		got := Optouts(guard, ParseRules(lines(c.Project), false))
		want := c.Want
		if c.Note != "" {
			want = []string{strings.TrimPrefix(c.Project, "!")}
		}
		if !slices.Equal(got, want) && !(len(got) == 0 && len(want) == 0) {
			t.Errorf("optouts(%q) = %q, want %q", c.Project, got, want)
		}
	}
	for _, c := range f.Tightens {
		if got := Tightens(ParseRules(lines(c.Old), false), ParseRules(lines(c.New), false)); got != c.Want {
			t.Errorf("tightens(%q, %q) = %v", c.Old, c.New, got)
		}
	}
}

// yamlKeys reads rendered YAML back as plain data, mapping keys as written.
func yamlKeys(n *yaml.Node) any {
	switch n.Kind {
	case yaml.DocumentNode:
		return yamlKeys(n.Content[0])
	case yaml.MappingNode:
		m := map[string]any{}
		for i := 0; i < len(n.Content); i += 2 {
			m[n.Content[i].Value] = yamlKeys(n.Content[i+1])
		}
		return m
	case yaml.SequenceNode:
		var s []any
		for _, c := range n.Content {
			s = append(s, yamlKeys(c))
		}
		return s
	}
	return n.Value
}

func TestRender(t *testing.T) {
	var f struct {
		Stub, Redacted string
		Cases          map[string]struct {
			Shape, Note string
			Keys        []string
			Tree        any
			Docs        []any
		}
	}
	readJSON(t, "render.json", &f)
	if len(f.Cases) < 30 {
		t.Fatal("render.json did not load")
	}
	if f.Stub != string(Stub) || f.Redacted != redacted {
		t.Fatal("the stub or the placeholder differs from the Python's")
	}
	for name, want := range f.Cases {
		out, shape := Render(filepath.Join(fixtures, "render", name))
		if strings.Contains(string(out), "s3cr3t") {
			t.Errorf("%s: a value leaked:\n%s", name, out)
		}
		switch {
		case name == "yaml-1.1-keys": // YAML 1.2: on/yes stay names
			want.Docs = []any{map[string]any{"on": redacted, "yes": redacted, "key": redacted}}
		case name == "json-nan": // Go's JSON refuses NaN; the YAML renderer takes it
			want.Shape, want.Docs = "yaml", []any{map[string]any{"a": redacted}}
		}
		if want.Shape == "stub" {
			want.Shape = ""
		}
		if shape != want.Shape {
			t.Errorf("%s: shape %q, want %q", name, shape, want.Shape)
			continue
		}
		var got any
		switch shape {
		case "dotenv":
			var keys []string
			for _, l := range strings.Split(strings.TrimSuffix(string(out), "\n"), "\n") {
				keys = append(keys, strings.TrimSuffix(l, "="+redacted))
			}
			got, want.Tree = keys, want.Keys
			if !slices.Equal(keys, want.Keys) {
				t.Errorf("%s: keys %q, want %q", name, keys, want.Keys)
			}
			continue
		case "json":
			if err := json.Unmarshal(out, &got); err != nil {
				t.Fatalf("%s: %v\n%s", name, err, out)
			}
		case "yaml":
			dec := yaml.NewDecoder(strings.NewReader(string(out)))
			var docs []any
			for {
				var n yaml.Node
				if dec.Decode(&n) != nil {
					break
				}
				docs = append(docs, yamlKeys(&n))
			}
			got, want.Tree = docs, want.Docs
		default:
			if string(out) != string(Stub) {
				t.Errorf("%s: not the stub", name)
			}
			continue
		}
		if !reflect.DeepEqual(got, want.Tree) {
			t.Errorf("%s: got %v, want %v\n%s", name, got, want.Tree, out)
		}
	}
}

func TestGitConfig(t *testing.T) {
	var f struct {
		AmbiguousEntry []string `json:"ambiguous_entry"`
		Entries        []struct {
			Text string
			Want [][]string
		}
		WriteOK []struct {
			Candidate string
			Current   *string
			Want      bool
		} `json:"write_ok"`
	}
	readJSON(t, "gitconfig.json", &f)
	if len(f.Entries) < 30 || len(f.WriteOK) == 0 {
		t.Fatal("gitconfig.json did not load")
	}
	if !slices.Equal(f.AmbiguousEntry, AmbiguousEntry[:]) {
		t.Fatal("AmbiguousEntry differs")
	}
	for _, c := range f.Entries {
		var got [][]string
		for _, e := range GitIniEntries(c.Text) {
			got = append(got, e[:])
		}
		if !reflect.DeepEqual(got, c.Want) && !(len(got) == 0 && len(c.Want) == 0) {
			t.Errorf("entries(%q) = %q, want %q", c.Text, got, c.Want)
		}
	}
	for _, c := range f.WriteOK {
		var cur []byte
		var err error = os.ErrNotExist
		if c.Current != nil {
			cur, err = []byte(*c.Current), nil
		}
		if got := gitConfigWriteOK([]byte(c.Candidate), cur, err); got != c.Want {
			t.Errorf("write %q over %v = %v", c.Candidate, c.Current, got)
		}
	}
}
