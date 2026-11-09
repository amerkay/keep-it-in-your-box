//go:build !linux

package main

func serveFUSE(*view, string, func() []Rule) { die(exitUsage, "kib-view: fuse is Linux only") }
