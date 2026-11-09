package main

// `.kibignore` rules: parsed and matched in exactly one place (the spec is
// tests/fixtures/redaction/rules.json). Matching folds case (fold): on a case-insensitive disk
// `.ENV` opens the real `.env`.

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"unicode"
)

const (
	Redact  = "redact"
	Protect = "protect"
)

type anchor int

const (
	bare  anchor = iota // one segment, any depth, never under .git
	exact               // the whole path, from the project root
	tail                // trailing components, any depth (guard rules only)
)

type Rule struct {
	Negated bool
	Pattern string // as written, for messages
	Anchor  anchor
	Action  string
	Immune  bool // a guard rule: a project's '!' cannot cancel it
	parts   [][]rune
}

func (r Rule) String() string {
	if r.Negated {
		return "!" + r.Pattern
	}
	return r.Pattern
}

// isSpace is Python's str.isspace, which unicode.IsSpace misses U+001C–U+001F of.
func isSpace(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) }

func trim(s string) string { return strings.TrimFunc(s, isSpace) }

// ParseRules reads rule lines in order; unsafe rules are dropped with a warning.
func ParseRules(lines []string, guard bool) []Rule {
	var out []Rule
	action := Redact
	for _, raw := range lines {
		line := trim(strings.SplitN(raw, "#", 2)[0])
		if line == "" {
			continue
		}
		if guard && strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section := strings.ToLower(trim(line[1 : len(line)-1]))
			if section != Protect && section != Redact {
				fmt.Fprintf(os.Stderr, "kib: unknown guard section %q\n", line)
				continue
			}
			action = section
			continue
		}
		negated := strings.HasPrefix(line, "!")
		if negated {
			line = trim(line[1:])
		}
		line = strings.TrimRight(line, "/")
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "/") || contains(strings.Split(line, "/"), "..") {
			fmt.Fprintf(os.Stderr, "kib: skipping unsafe rule %q\n", line)
			continue
		}
		r := Rule{Negated: negated, Pattern: line, Action: action, Immune: guard, Anchor: tail}
		if !guard {
			r.Action, r.Anchor = Redact, bare
			if strings.Contains(line, "/") {
				r.Anchor = exact
			}
		}
		for _, p := range strings.Split(fold(line), "/") {
			r.parts = append(r.parts, []rune(p))
		}
		out = append(out, r)
	}
	return out
}

// LoadRules parses a rule file; an absent file is an empty rule set.
func LoadRules(path string, guard bool) ([]Rule, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	defer f.Close()
	var lines []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	return ParseRules(lines, guard), sc.Err()
}

// ligatures: the full case folds that spell plain ASCII (U+00DF, U+FB00–FB06).
var ligatures = strings.NewReplacer("ß", "ss", "ﬀ", "ff", "ﬁ", "fi", "ﬂ", "fl", "ﬃ", "ffi", "ﬄ", "ffl", "ﬅ", "st", "ﬆ", "st")

// fold is as wide as a case-insensitive disk's folding: APFS opens `.vſcode` (long s) as `.vscode`.
func fold(s string) string {
	return ligatures.Replace(strings.Map(func(r rune) rune {
		m := r
		for f := unicode.SimpleFold(r); f != r; f = unicode.SimpleFold(f) {
			m = min(m, f)
		}
		return unicode.ToLower(m)
	}, s))
}

func contains(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}

// matches compares one rule against an ancestor's components (already folded).
func (r *Rule) matches(parts []string, underGit bool) bool {
	if r.Anchor == bare {
		return !underGit && fnmatch(parts[len(parts)-1], r.parts[0])
	}
	if r.Anchor == tail {
		if len(r.parts) > len(parts) {
			return false
		}
		parts = parts[len(parts)-len(r.parts):]
	} else if len(r.parts) != len(parts) {
		return false
	}
	for i, p := range r.parts {
		if !fnmatch(parts[i], p) {
			return false
		}
	}
	return true
}

// Verdict is "", Redact or Protect for one project-relative path. Guard and project rules are
// tallied apart and the guard wins when it has a verdict, except that a project '!' cancels a
// [redact] guard rule matched at the SAME component. A matched proper ancestor seals the rest.
func Verdict(rules []Rule, rel string) string {
	// Exact case: bare rules stop inside the real .git only, never a look-alike `.GIT`.
	underGit := strings.Split(rel, "/")[0] == ".git"
	parts := strings.Split(fold(rel), "/")
	guard, project, effective := "", "", ""
	guardAt, optoutAt := -1, -1
	for i := 1; i <= len(parts); i++ {
		for j := range rules {
			r := &rules[j]
			if !r.matches(parts[:i], underGit) {
				continue
			}
			v := r.Action
			if r.Negated {
				v = ""
			}
			if r.Immune {
				guard, guardAt = v, i
			} else {
				project = v
				if r.Negated {
					optoutAt = i
				}
			}
		}
		effective = guard
		if guard == Redact && optoutAt == guardAt {
			effective = ""
		}
		if effective == "" {
			effective = project
		}
		if effective != "" && i < len(parts) {
			return effective
		}
	}
	return effective
}

// Optouts are the project '!' rules that may hand a guard-[redact] path back to the session:
// any that hits one literally, and any wildcard one (`!*` un-redacts every .env).
func Optouts(guard, project []Rule) []string {
	var out []string
	for _, r := range project {
		if r.Negated && (Verdict(guard, r.Pattern) == Redact ||
			strings.ContainsAny(r.Pattern, "*?[")) {
			out = append(out, r.Pattern)
		}
	}
	return out
}

func sameRule(a, b Rule) bool {
	return a.Negated == b.Negated && a.Pattern == b.Pattern && a.Anchor == b.Anchor &&
		a.Action == b.Action && a.Immune == b.Immune
}

// Tightens is true if `new` can only withhold MORE than `old`: every old rule kept, in order,
// and none of the added ones negated. Order matters: rules are last-match-wins.
func Tightens(old, new []Rule) bool {
	i := 0
	for _, o := range old {
		for i < len(new) && !sameRule(new[i], o) {
			i++
		}
		if i == len(new) {
			return false
		}
		i++
	}
	for _, n := range new {
		kept := false
		for _, o := range old {
			kept = kept || sameRule(n, o)
		}
		if n.Negated && !kept {
			return false
		}
	}
	return true
}

// fnmatch is Python's fnmatch.fnmatch on one path component: `*`, `?`, `[...]` with a leading
// `!` for negation and a leading `]` literal, an unclosed `[` literal, backslash always literal.
func fnmatch(name string, pat []rune) bool {
	s := []rune(name)
	si, pi, starP, starS := 0, 0, -1, 0
	for si < len(s) {
		if pi < len(pat) {
			switch pat[pi] {
			case '*':
				starP, starS = pi, si
				pi++
				continue
			case '?':
				si, pi = si+1, pi+1
				continue
			case '[':
				if ok, next, valid := class(pat, pi, s[si]); valid {
					if ok {
						si, pi = si+1, next
						continue
					}
					break
				}
				if s[si] == '[' {
					si, pi = si+1, pi+1
					continue
				}
			default:
				if pat[pi] == s[si] {
					si, pi = si+1, pi+1
					continue
				}
			}
		}
		if starP < 0 {
			return false
		}
		starS++
		si, pi = starS, starP+1
	}
	for pi < len(pat) && pat[pi] == '*' {
		pi++
	}
	return pi == len(pat)
}

// class matches c against the `[...]` at pat[i]; valid is false for an unclosed `[`.
func class(pat []rune, i int, c rune) (ok bool, next int, valid bool) {
	j := i + 1
	neg := j < len(pat) && pat[j] == '!'
	if neg {
		j++
	}
	start := j
	if j < len(pat) && pat[j] == ']' {
		j++
	}
	for j < len(pat) && pat[j] != ']' {
		j++
	}
	if j >= len(pat) {
		return false, 0, false
	}
	set := pat[start:j] // never empty: a leading `]` is a member
	for k := 0; k < len(set); {
		if k+2 < len(set) && set[k+1] == '-' {
			ok = ok || (set[k] <= c && c <= set[k+2])
			k += 3
		} else {
			ok = ok || set[k] == c
			k++
		}
	}
	return ok != neg, j + 1, true
}
