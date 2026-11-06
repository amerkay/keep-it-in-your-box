package main

// What a redacted file reads as: its key names with every value replaced, or a flat stub. The
// shape is sniffed, never read off the name, and each renderer vouches for the WHOLE file or
// declines it. Output is built from parsed keys only, so no byte of a value can pass through.
// Spec: tests/fixtures/redaction/render.json.

import (
	"bytes"
	"encoding/json"
	"io"
	"regexp"
	"strings"
	"unicode/utf8"

	"go.yaml.in/yaml/v3"
)

var Stub = []byte("# REDACTED BY .kibignore — hidden from this Claude Code Docker sandbox" +
	" by user policy.\n" +
	"# Intentional, not an error. All access paths return this stub; writes return EPERM.\n" +
	"# Ask the user directly if you need the contents — don't try to work around it.\n")

const (
	redacted  = "<redacted>"
	renderMax = 64 * 1024 // characters: config and credential files, never bigger
	maxDepth  = 100       // nesting deeper than any config; output grows with depth squared
)

// Python's \s, which is Unicode-wide (RE2's is ASCII).
const ws = `[\t\n\v\f\r\x1c-\x1f \x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}]`

var (
	dotenvKey = regexp.MustCompile(`^` + ws + `*(?:export` + ws + `+)?([A-Za-z_][A-Za-z0-9_]*)` + ws + `*=`)
	// One `key:` line: the cheap necessary condition for a YAML mapping, before any parse.
	yamlMapping = regexp.MustCompile(`(?m)^` + ws + `*[^\s#][^:\n]*:(?:\s|$)`)
	lineBreaks  = strings.NewReplacer("\r\n", "\n", "\r", "\n")
)

// Render serves a redacted file; the shape is "" for the stub.
func Render(f io.Reader) ([]byte, string) {
	raw, err := io.ReadAll(io.LimitReader(f, 4*(renderMax+2)))
	if err != nil || !utf8.Valid(raw) {
		return Stub, ""
	}
	// utf-8-sig and Python's universal newlines: what the renderers were written against.
	text := lineBreaks.Replace(strings.TrimPrefix(string(raw), "\ufeff"))
	if utf8.RuneCountInString(text) > renderMax {
		return Stub, ""
	}
	for _, r := range []struct {
		name string
		fn   func(string) []byte
	}{{"dotenv", renderDotenv}, {"json", renderJSON}, {"yaml", renderYAML}} {
		if out := r.fn(text); out != nil {
			return out, r.name
		}
	}
	return Stub, ""
}

// splitLines is Python's str.splitlines, after the newline folding above.
func splitLines(s string) []string {
	var out []string
	start := 0
	for i, r := range s {
		if strings.ContainsRune("\n\v\f\x1c\x1d\x1e\u0085\u2028\u2029", r) {
			out = append(out, s[start:i])
			start = i + utf8.RuneLen(r)
		}
	}
	if start < len(s) {
		out = append(out, s[start:])
	}
	return out
}

// renderDotenv is `KEY=<redacted>` per assignment, or nil unless EVERY line is blank, a
// comment or an assignment; a multi-line quoted value declines (its lines look like keys).
func renderDotenv(text string) []byte {
	var b strings.Builder
	for _, line := range splitLines(text) {
		m := dotenvKey.FindStringSubmatchIndex(line)
		if m == nil {
			if t := trim(line); t != "" && !strings.HasPrefix(t, "#") {
				return nil
			}
			continue
		}
		value := strings.TrimLeftFunc(line[m[1]:], isSpace)
		if q := value[:min(1, len(value))]; q == `"` || q == "'" {
			end := strings.TrimRightFunc(value[1:], isSpace)
			if !strings.HasSuffix(end, q) || strings.HasSuffix(end, `\`+q) {
				return nil
			}
		}
		b.WriteString(line[m[2]:m[3]] + "=" + redacted + "\n")
	}
	if b.Len() == 0 {
		return nil
	}
	return []byte(b.String())
}

// renderJSON keeps keys in file order (a duplicate keeps its first place, as Python's does).
func renderJSON(text string) []byte {
	dec := json.NewDecoder(strings.NewReader(text))
	var out bytes.Buffer
	if !scrubJSON(dec, &out, 0) {
		return nil
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil // trailing data
	}
	out.WriteByte('\n')
	return out.Bytes()
}

func scrubJSON(dec *json.Decoder, out *bytes.Buffer, depth int) bool {
	tok, err := dec.Token()
	if err != nil || depth > maxDepth {
		return false
	}
	pad := "\n" + strings.Repeat("  ", depth+1)
	switch tok {
	case json.Delim('{'):
		var keys []string
		seen := map[string]bool{}
		var vals []bytes.Buffer
		for dec.More() {
			k, err := dec.Token()
			ks, isStr := k.(string)
			if err != nil || !isStr {
				return false
			}
			var v bytes.Buffer
			if !scrubJSON(dec, &v, depth+1) {
				return false
			}
			if !seen[ks] {
				seen[ks] = true
				keys = append(keys, ks)
				vals = append(vals, v)
			}
		}
		if _, err := dec.Token(); err != nil {
			return false
		}
		if len(keys) == 0 {
			out.WriteString("{}")
			return true
		}
		out.WriteString("{")
		for i, k := range keys {
			kb, _ := json.Marshal(k)
			out.WriteString(pad + string(kb) + ": " + vals[i].String())
			if i < len(keys)-1 {
				out.WriteString(",")
			}
		}
		out.WriteString(pad[:len(pad)-2] + "}")
	case json.Delim('['):
		var items []string
		for dec.More() {
			var v bytes.Buffer
			if !scrubJSON(dec, &v, depth+1) {
				return false
			}
			items = append(items, v.String())
		}
		if _, err := dec.Token(); err != nil {
			return false
		}
		if len(items) == 0 {
			out.WriteString("[]")
			return true
		}
		out.WriteString("[" + pad + strings.Join(items, ","+pad) + pad[:len(pad)-2] + "]")
	default:
		out.WriteString(`"` + redacted + `"`)
	}
	return true
}

// renderYAML is `key: <redacted>` per mapping entry. An alias anywhere declines, found on the
// node tree, which never expands one: a billion-laughs file must not exhaust the sidecar.
func renderYAML(text string) []byte {
	if !strings.Contains(text, ":") || !yamlMapping.MatchString(text) {
		return nil
	}
	dec := yaml.NewDecoder(strings.NewReader(text))
	var out bytes.Buffer
	enc := yaml.NewEncoder(&out)
	enc.SetIndent(2)
	docs := 0
	for {
		var doc yaml.Node
		if err := dec.Decode(&doc); err == io.EOF {
			break
		} else if err != nil || len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
			return nil
		}
		scrubbed := scrubYAML(doc.Content[0], 0)
		if scrubbed == nil || enc.Encode(scrubbed) != nil {
			return nil
		}
		docs++
	}
	if docs == 0 || enc.Close() != nil {
		return nil
	}
	return out.Bytes()
}

func scrubYAML(n *yaml.Node, depth int) *yaml.Node {
	if depth > maxDepth {
		return nil
	}
	switch n.Kind {
	case yaml.AliasNode:
		return nil
	case yaml.MappingNode:
		m := &yaml.Node{Kind: yaml.MappingNode}
		seen := map[string]bool{}
		for i := 0; i+1 < len(n.Content); i += 2 {
			k := n.Content[i]
			if k.Kind != yaml.ScalarNode {
				return nil // a complex key: Python's loader refuses one too
			}
			v := scrubYAML(n.Content[i+1], depth+1)
			if v == nil {
				return nil
			}
			if !seen[k.Value] {
				seen[k.Value] = true
				m.Content = append(m.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: k.Value}, v)
			}
		}
		return m
	case yaml.SequenceNode:
		s := &yaml.Node{Kind: yaml.SequenceNode}
		for _, c := range n.Content {
			v := scrubYAML(c, depth+1)
			if v == nil {
				return nil
			}
			s.Content = append(s.Content, v)
		}
		return s
	}
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: redacted}
}
