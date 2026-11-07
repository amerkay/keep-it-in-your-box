// kib-fuse: the sandbox's redacting view of the project, and the rule checks the host asks of
// it. One binary, so `.kibignore` is matched by exactly one implementation.
//
//	fuse --src DIR --mnt DIR --patterns-file F --guard-file F [--uid N --gid N]
//	fuse optouts GUARD RULES       project '!' rules that un-redact, one per line
//	fuse tightens OLD NEW          exit 0 if NEW can only withhold more, else 5
//	fuse match RULES               the NUL-separated paths on stdin that RULES covers, likewise
//
// A file argument of "-" reads stdin.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
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
			die(1, "kib-fuse: %v", err)
		}
		return r
	}
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		die(1, "kib-fuse: %v", err)
	}
	return ParseRules(strings.Split(string(raw), "\n"), guard)
}

func main() {
	if len(os.Args) > 1 && !strings.HasPrefix(os.Args[1], "-") {
		os.Exit(subcommand(os.Args[1], os.Args[2:]))
	}
	serve()
}

func subcommand(cmd string, args []string) int {
	need := map[string]int{"optouts": 2, "tightens": 2, "match": 1}[cmd]
	if need == 0 || len(args) != need {
		die(exitUsage, "usage: fuse optouts GUARD RULES | tightens OLD NEW | match RULES")
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
			die(1, "kib-fuse: %v", err)
		}
		for _, p := range strings.Split(string(paths), "\x00") {
			if p != "" && Verdict(rules, p) != "" {
				fmt.Print(p + "\x00")
			}
		}
	}
	return 0
}

func serve() {
	src := flag.String("src", "", "the project")
	mnt := flag.String("mnt", "", "where the view mounts")
	// Both required: an optional guard file fails OPEN (a view with no rules reported as up).
	// "No rules" is an EMPTY file, never a missing flag.
	patterns := flag.String("patterns-file", "", "the project's staged rules")
	guardFile := flag.String("guard-file", "", "kib's guard rules")
	uid := flag.Int64("uid", -1, "report this owner in the project root's owner's place")
	gid := flag.Int64("gid", -1, "report this group in the project root's group's place")
	flag.Parse()
	if *src == "" || *mnt == "" || *patterns == "" || *guardFile == "" {
		die(exitUsage, "kib-fuse: --src, --mnt, --patterns-file and --guard-file are required")
	}
	build := func() []Rule {
		g, err := LoadRules(*guardFile, true)
		if err != nil {
			die(1, "kib-fuse: %v", err)
		}
		p, err := LoadRules(*patterns, false)
		if err != nil {
			die(1, "kib-fuse: %v", err)
		}
		return append(g, p...)
	}
	rules := build()
	v, err := newView(*src, rules, *uid, *gid)
	if err != nil {
		die(1, "kib-fuse: %v", err)
	}
	var lim syscall.Rlimit
	_ = syscall.Getrlimit(syscall.RLIMIT_NOFILE, &lim) // Go raised the soft limit at start
	guards := 0
	for _, r := range rules {
		if r.Immune {
			guards++
		}
	}
	logf("kib-fuse: src=%s mnt=%s guard=%d remap=%d:%d->%d:%d nofile=%d rules=%v",
		*src, *mnt, guards, v.baseUID, v.baseGID, *uid, *gid, lim.Cur, rules)

	server, err := fs.Mount(*mnt, v.root, mountOptions(true))
	if err != nil {
		die(1, "kib-fuse: mount: %v", err)
	}
	sig := make(chan os.Signal, 4)
	signal.Notify(sig, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		for s := range sig {
			if s != syscall.SIGHUP {
				_ = server.Unmount()
				continue
			}
			rules := build()
			v.reload(rules)
			logf("kib-fuse: reloaded rules=%v", rules)
		}
	}()
	server.Wait()
}

// mountOptions: libfuse's 1 s entry and attr timeouts, as the Python view had.
func mountOptions(allowOther bool) *fs.Options {
	sec := time.Second
	return &fs.Options{
		EntryTimeout: &sec,
		AttrTimeout:  &sec,
		MountOptions: fuse.MountOptions{
			AllowOther: allowOther, // the box's root entrypoint reads the view as well as its user
			FsName:     "kib-fuse",
			Name:       "kib",
			// The backing syscalls run as the server, so without this a `chmod 000` file reads
			// fine: the kernel re-checks owner and mode against the CALLER on every op.
			Options:       []string{"default_permissions"},
			DisableXAttrs: true,
		},
	}
}
