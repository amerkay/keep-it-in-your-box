package main

// The git-INI entries that name a command the host would run, read the way GIT reads the file
// (kib/shared/dangerous.py keeps the host's copy; tests/fixtures/redaction/gitconfig.json keeps
// both in step). git resumes after `]`, a quoted subsection may hold `]`, `#` or `;`, and git
// drops one leading BOM and ends lines at `\n` only: anything a Unicode reader would split
// differently is refused outright.

import (
	"sort"
	"strings"
	"unicode/utf8"
)

var (
	gitKeys = set(strings.Fields(`hookspath fsmonitor sshcommand pager editor askpass gitproxy
		external textconv command driver clean smudge process helper templatedir program cmd
		variant packobjectshook uploadpack receivepack update difffilter defaultkeycommand`))
	gitSections = set([]string{"alias", "pager", "include", "includeif"})
	ambiguous   = "\ufeff\r\v\f\x1c\x1d\x1e\u0085\u2028\u2029"
	// AmbiguousEntry stands in for "this file cannot be parsed unambiguously".
	AmbiguousEntry = [3]string{"<file>", "<ambiguous line separator>", ""}
)

func set(xs []string) map[string]bool {
	m := map[string]bool{}
	for _, x := range xs {
		m[x] = true
	}
	return m
}

// stripComment drops a `#`/`;` comment outside double quotes; a backslash escapes in a quote.
func stripComment(s string) string {
	var b strings.Builder
	inQ := false
	r := []rune(s)
	for i := 0; i < len(r); i++ {
		c := r[i]
		if c == '\\' && inQ && i+1 < len(r) {
			b.WriteRune(c)
			b.WriteRune(r[i+1])
			i++
			continue
		}
		if c == '"' {
			inQ = !inQ
		} else if (c == '#' || c == ';') && !inQ {
			break
		}
		b.WriteRune(c)
	}
	return b.String()
}

// splitHeader returns the lower-cased section and what follows the closing `]` outside quotes.
func splitHeader(line string) (string, string) {
	r := []rune(line)
	first := func(head string) string {
		f := strings.FieldsFunc(head, isSpace)
		if len(f) == 0 {
			return ""
		}
		return strings.ToLower(strings.Trim(f[0], `"`))
	}
	inQ := false
	for i := 1; i < len(r); i++ {
		c := r[i]
		if c == '\\' && inQ && i+1 < len(r) {
			i++
			continue
		}
		if c == '"' {
			inQ = !inQ
		} else if c == ']' && !inQ {
			return first(string(r[1:i])), strings.TrimFunc(string(r[i+1:]), isSpace)
		}
	}
	return first(string(r[1:])), ""
}

func entriesIn(lines []string, found map[[3]string]bool) {
	section := ""
	for _, raw := range lines {
		line := strings.TrimFunc(stripComment(raw), isSpace)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") {
			section, line = splitHeader(line)
			if line == "" {
				continue
			}
		}
		key, value, _ := strings.Cut(line, "=")
		key = strings.ToLower(strings.TrimFunc(key, isSpace))
		parts := strings.Split(key, ".")
		if gitSections[section] || gitKeys[parts[len(parts)-1]] {
			found[[3]string{section, key, strings.TrimFunc(value, isSpace)}] = true
		}
	}
}

// GitIniEntries are the (section, key, value) triples in text that name a command, sorted.
func GitIniEntries(text string) [][3]string {
	text = strings.ReplaceAll(strings.TrimPrefix(text, "\ufeff"), "\r\n", "\n")
	found := map[[3]string]bool{}
	entriesIn(strings.Split(text, "\n"), found)
	if strings.ContainsAny(text, ambiguous) {
		entriesIn(splitLines(lineBreaks.Replace(text)), found)
		found[AmbiguousEntry] = true
	}
	out := make([][3]string, 0, len(found))
	for e := range found {
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool {
		return strings.Join(out[i][:], "\x00") < strings.Join(out[j][:], "\x00")
	})
	return out
}

// gitConfigWriteOK allows a new config only if it ADDS no command-valued entry: one the repo
// already has (a git-lfs filter) is the user's own. Unreadable or undecodable fails closed.
func gitConfigWriteOK(candidate, current []byte, currentErr error) bool {
	if !utf8.Valid(candidate) {
		return false
	}
	old := map[[3]string]bool{}
	if currentErr == nil && utf8.Valid(current) {
		for _, e := range GitIniEntries(string(current)) {
			old[e] = true
		}
	}
	for _, e := range GitIniEntries(string(candidate)) {
		if !old[e] {
			logf("kib-view: refusing git config write — '%s.%s' names a command the host "+
				"would execute (or the file has an ambiguous line separator)", e[0], e[1])
			return false
		}
	}
	return true
}
