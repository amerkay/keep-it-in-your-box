# TMP checklist: finish the VM work (delete when merged)

Branch `feat/vm-security`. Every step runs in a host terminal.

## 0. Smoke test before closing your sessions (Linux, ~10 min) — ✅ passed 2026-11-06

A separate VM and state folder, so your running sessions are never touched. Use the same
`export` line in **every** terminal of this test.

Terminal A:

```
cd ~/kib-vm-test
export XDG_STATE_HOME=$HOME/kib-vm-test-state LIMA_HOME=$HOME/kib-vm-test-lima KIB_VM=on
kib
```

Expect: at most one install prompt (only if buildx is missing), the VM created, the image built
in it, the sync line, then Claude. In Claude, type `! uname -r` (must differ from `uname -r` in
terminal B) and `! grep -c " $HOME/.cache " /proc/self/mountinfo` (must print 1: the cache
volume).

Terminal B, while Claude runs in A:

```
cd ~/keep-it-in-your-box
export XDG_STATE_HOME=$HOME/kib-vm-test-state LIMA_HOME=$HOME/kib-vm-test-lima KIB_VM=on
./tests/vm-check.sh
echo hello-from-host >~/kib-vm-test/smoke.txt
```

Expect every line ✔. In Claude: `! cat smoke.txt` prints `hello-from-host`.

Back in A: quit Claude. Expect "the VM stops in 10 min unless one opens" and your prompt back.
Run `kib` again: no VM boot this time. Quit again.

Clean up (terminal B):

```
limactl delete -f kib-vm
PATH="$PATH:$HOME/.local/bin" MUTAGEN_DATA_DIRECTORY=$HOME/kib-vm-test-state/kib-mutagen mutagen daemon stop
rm -rf ~/kib-vm-test-state ~/kib-vm-test-lima ~/kib-vm-test/smoke.txt
unset XDG_STATE_HOME LIMA_HOME KIB_VM
```

If any step fails, keep your sessions open and send me the output.

## 1. Get the code onto both machines

Close all kib sessions first. Linux:

```
cd ~/keep-it-in-your-box
git push
kib build
```

Mac:

```
cd ~/keep-it-in-your-box
git pull
kib build
```

## 2. Checks, on Linux (`vm = on`) and on the Mac

- [ ] A session starts in a real project, with at most one install prompt
- [ ] `./tests/vm-check.sh` with a session open: every line ✔
- [ ] In the box: `./tests/security-test.sh` passes. "Engine VM": another kernel, `~/.cache`
      the cache volume. Mac: the AppArmor label line passes under Lima
- [ ] Sync: host edit shows in the box < 1 s; box edit shows on the host; both edit one file →
      the host's version is kept
- [ ] Big project: the sync line names the file being copied; `vm_skip = …` in
      `~/.keep-it-in-your-box/config` skips a folder
- [ ] Mid-session `.kibignore`: put `kibtestvalue` in a file, add a rule for it. Within seconds
      the box reads it redacted, and both print nothing:
      ```
      grep -r kibtestvalue ~/.local/state/kib-shadow/
      limactl shell kib-vm sudo grep -rl kibtestvalue /var/lib/docker/volumes/
      ```
- [ ] Package cache: `pnpm install`, close, reopen, `pnpm install` again: no download.
      `kib-<project>-<hash>-cache` is still in `docker volume ls` after the close
- [ ] Reopen within 10 min: no VM boot, and the sync line passes in a second or two. 10 min
      after the last close: `limactl list` shows `kib-vm` Stopped, and the next launch copies the
      whole project again (its old copy went with the VM)
- [ ] Mac: `git status` works in the box; image paste (Ctrl+V) works
- [ ] Linux: `--resume` shows the same history with and without the VM

## 3. Housekeeping

- [ ] `~/kib-vm-test/.kibignore`: delete the `!.env` line left from the Phase 4 test (an opt-out
      syncs `.env` in full, and `vm-check` rightly reports its value)
- [ ] `sn-workspace`: drop pnpm `store-dir`/`storeDir` and uv `cache-dir` if set; delete its
      `.pnpm-store`
- [ ] With no Linux session open, tell Claude "fix bin/kib": a stale comment, and `kib build`
      alone starts the VM without the 10-minute stop timer
- [ ] Remove the native Docker leftovers on Linux (below)
- [ ] Happy? Tell Claude "merge"

## Docker cleanup on Linux

Only once `vm = on` is in `~/.keep-it-in-your-box/config` and no non-VM kib runs. The first
line makes sure these reach the host's Docker, not the VM's.

```
unset DOCKER_HOST
docker ps -a --filter name=^kib-
docker ps -aq --filter name=^kib- | xargs -r docker rm -f
docker volume ls -q --filter name=^kib- | xargs -r docker volume rm
docker network ls -q --filter name=^kib-broker-net- | xargs -r docker network rm
docker images -q keep-it-in-your-box | xargs -r docker rmi -f
docker builder prune -f
```

If nothing else on this machine uses Docker, remove it (Docker's apt packages; Ubuntu's own is
`docker.io`). kib then offers to install its own `docker` command and buildx into `~/.local`:

```
sudo systemctl disable --now docker.service docker.socket containerd.service
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo rm -rf /var/lib/docker /var/lib/containerd
```
- [ ] Dockerfile: drop `python3-yaml` and its smoke test (kib no longer uses it) the next time the apt layer changes anyway — editing it now costs a ~10 min rebuild.
