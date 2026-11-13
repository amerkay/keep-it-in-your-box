// kib-view: the project's redacting view, run on the host, and the rule checks kib asks of it.
// One binary, so `.kibignore` is matched by exactly one implementation.
//
//	kib-view nfs  --src DIR --patterns-file F --guard-file F   serve NFS; prints "<port> <secret>"
//	kib-view fuse --src DIR --patterns-file F --guard-file F --mnt DIR   (Linux) mount with FUSE
//	kib-view optouts GUARD RULES   project '!' rules that un-redact, one per line
//	kib-view tightens OLD NEW      exit 0 if NEW can only withhold more, else 5
//	kib-view match RULES           the NUL-separated paths on stdin that RULES covers, likewise
//
// A file argument of "-" reads stdin. SIGHUP re-reads both rule files into a running view.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
)

const (
	exitUsage   = 2
	exitRefused = 5 // kib/shared/cli.py REFUSED
)

func logf(format string, a ...any) { fmt.Fprintf(os.Stderr, format+"\n", a...) }

func die(code int, format string, a ...any) {
	logf(format, a...)
	os.Exit(code)
}

func load(path string, guard bool) []Rule {
	if path != "-" {
		r, err := LoadRules(path, guard)
		if err != nil {
			die(1, "kib-view: %v", err)
		}
		return r
	}
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		die(1, "kib-view: %v", err)
	}
	return ParseRules(strings.Split(string(raw), "\n"), guard)
}

func main() {
	cmd, args := "", []string{}
	if len(os.Args) > 1 {
		cmd, args = os.Args[1], os.Args[2:]
	}
	switch cmd {
	case "nfs", "fuse":
		serve(cmd, args)
	default:
		os.Exit(subcommand(cmd, args))
	}
}

func subcommand(cmd string, args []string) int {
	need := map[string]int{"optouts": 2, "tightens": 2, "match": 1}[cmd]
	if need == 0 || len(args) != need {
		die(exitUsage, "usage: kib-view nfs|fuse … | optouts GUARD RULES | tightens OLD NEW | match RULES")
	}
	switch cmd {
	case "optouts":
		for _, p := range Optouts(load(args[0], true), load(args[1], false)) {
			fmt.Println(p)
		}
	case "tightens":
		if !Tightens(load(args[0], false), load(args[1], false)) {
			return exitRefused
		}
	case "match":
		rules := load(args[0], false)
		paths, err := io.ReadAll(os.Stdin)
		if err != nil {
			die(1, "kib-view: %v", err)
		}
		for _, p := range strings.Split(string(paths), "\x00") {
			if p != "" && Verdict(rules, p) != "" {
				fmt.Print(p + "\x00")
			}
		}
	}
	return 0
}

func serve(mode string, args []string) {
	fl := flag.NewFlagSet(mode, flag.ExitOnError)
	src := fl.String("src", "", "the project")
	mnt := fl.String("mnt", "", "where the FUSE view mounts")
	allowOther := fl.Bool("allow-other", false, "FUSE: let other users (rootful Docker) in")
	// Both required: an optional guard file fails OPEN (a view with no rules reported as up).
	// "No rules" is an EMPTY file, never a missing flag.
	patterns := fl.String("patterns-file", "", "the project's staged rules")
	guardFile := fl.String("guard-file", "", "kib's guard rules")
	_ = fl.Parse(args)
	if *src == "" || *patterns == "" || *guardFile == "" || (mode == "fuse") != (*mnt != "") {
		die(exitUsage, "kib-view: --src, --patterns-file and --guard-file are required; --mnt with fuse only")
	}
	build := func() []Rule { return append(load(*guardFile, true), load(*patterns, false)...) }
	rules := build()
	v, err := newView(*src, rules)
	if err != nil {
		die(1, "kib-view: %v", err)
	}
	logf("kib-view: %s src=%s rules=%v", mode, v.src, rules)
	if mode == "fuse" {
		serveFUSE(v, *mnt, *allowOther, build)
		return
	}
	serveNFS(v, build)
}

// onSignals runs reload on SIGHUP and stop on SIGTERM/SIGINT.
func onSignals(reload, stop func()) {
	sig := make(chan os.Signal, 4)
	signal.Notify(sig, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		for s := range sig {
			if s == syscall.SIGHUP {
				reload()
			} else {
				stop()
			}
		}
	}()
}
