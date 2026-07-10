# deckhand

The one who does useful work aboard: a statically linked, libc-free Linux
binary (x86_64 + aarch64) for **container diagnostics**, served by
`Stevedore.Testing.runnable_image/1`. One command core, three
frontends — a REPL that also prints unsolicited events, a minimal
GET-only web server whose **URL space is the command set**, so an outsider
can inspect how the app inside the container sees its world, and
busybox-style **applets** that run one command to completion for the
run-to-completion process shapes.

## Invocation

    deckhand [PORT]          # REPL + server on PORT (default 8080), on 0.0.0.0 and ::
    deckhand APPLET [ARG]    # run one applet to completion (an all-digits
                             # first arg is a PORT; anything else an applet)

**Every command is an applet**, also reached busybox-style via **argv[0]
symlinks** — the runnable image ships one per command (`/bin/cat`,
`/bin/env`, `/bin/id`, `/bin/hostname`, `/bin/uname`, `/bin/ifaces`,
`/bin/mounts`, `/bin/ls`, `/bin/find`, `/bin/ping`, `/bin/ping6`,
`/bin/resolve`, `/bin/help`, `/bin/sleep`, `/bin/exit`, `/bin/true`,
`/bin/false`, `/bin/await-sig` → `deckhand`). An applet is not a PTY
citizen: plain stdout, no banner, no events, exit 0 (or the applet's code:
`exit N`, `false`). Still nothing shell-shaped (no pipes, no flags, no
globbing, no `$VAR` expansion); a test needing more uses a real image.

A **second instance in the same netns** finds the port taken and degrades
gracefully to REPL-only (`port N already in use (another deckhand aboard?) —
REPL-only, webserver disabled`) — deliberate, so tests can exec a second
process inside an already-running container. If only one address family's
port is taken, it serves on the other and says so.

## Commands = paths

| REPL        | HTTP           | applet       | shows                                        |
| ----------- | -------------- | ------------ | -------------------------------------------- |
| `help`      | `GET /`        | `help`       | this list                                    |
| `env`       | `GET /env`     | `env`        | environment variables                        |
| `id`        | `GET /id`      | `id`         | uid/euid/gid/egid                            |
| `hostname`  | `GET /hostname`| `hostname`   | nodename (UTS namespace)                     |
| `uname`     | `GET /uname`   | `uname`      | kernel sysname/release/machine               |
| `ifaces`    | `GET /ifaces`  | `ifaces`     | interface addresses, IPv4 + IPv6             |
| `mounts`    | `GET /mounts`  | `mounts`     | `/proc/mounts`                               |
| `cat PATH`  | `GET /cat/PATH`| `cat [PATH]` | one file, byte-for-byte — rootfs-content probes. Applet with **no PATH: stdin→stdout until EOF** (the run-to-completion echo shape) |
| `ls PATH`   | `GET /ls/PATH` | `ls PATH`    | directory entries, `/`-suffixed for dirs (`PATH` defaults to `/`) |
| `find PATH` | `GET /find/PATH` | `find PATH` | recursive path listing; symlinks printed, never followed |
| `ping H`    | `GET /ping/H`  | `ping H`     | one ICMP echo; IPv4/IPv6 literal or DNS name (names prefer A, falling back to AAAA) |
| `ping6 H`   | `GET /ping6/H` | `ping6 H`    | one ICMPv6 echo, forced IPv6 (AAAA only) — proves the v6 path to a dual-stack host |
| `resolve N` | `GET /resolve/N` | `resolve N` | A + AAAA via a stub resolver (`/etc/resolv.conf`) |
| `sleep N`   | `GET /sleep/N` | `sleep N`    | sleep `N` seconds, then return (REPL/HTTP block for the duration — a delayed-response endpoint; the applet has default signal dispositions, so TERM/INT kill it like coreutils sleep) |
| `true`      | `GET /true`    | `true`       | nothing, successfully (applet: exit 0)       |
| `false`     | `GET /false`   | `false`      | nothing, unsuccessfully (applet: exit 1)     |
| `exit [N]`  | —              | `exit [N]`   | leave with status `N` (default 0). Never over HTTP: remote peers must not be able to kill the container |
| —           | —              | `await-sig`  | block until **any** signal arrives (no REPL, no webserver), print its details as one line — name, number, `si_code`, sender pid/uid, and for `WINCH` the new console size — then exit 0. That line is its only output, so a test can assert signal (or PTY-resize) delivery verbatim. KILL/STOP are unblockable and never reported |

Unsolicited console events: `event: resize 120x40` (SIGWINCH → `TIOCGWINSZ`,
for PTY-resize plumbing tests), `event: signal TERM` (TERM/INT also exit 0,
gracefully), `event: GET /ifaces from 172.17.0.3:54812` (every HTTP hit), and
`event: stdin closed` (EOF — the server keeps running, so `deckhand` works as
a detached container entrypoint).

Implementation notes: single-threaded `ppoll` event loop, no libc, no
allocator; unprivileged ICMP sockets with a raw-socket fallback (containers
running as root have `CAP_NET_RAW`); DNS is a deliberately minimal stub — one
UDP query to the first `nameserver`, no search domains, no TCP fallback.
`ping`/`resolve` requests block the loop for at most their 2 s timeout;
`sleep` blocks it for the full duration (it's a test image — a wedged loop
is the caller's own doing).

> **Not a production sidecar.** `GET /env` exposes the container's
> environment — secrets included — *by design*: this is a test and diagnostic
> image. Never bake deckhand into a production workload.

## Toolchain pin & reproducibility

Built with **Zig 0.16.0** (`build.sh` refuses any other version):

    ./build.sh           # or ZIG=/path/to/zig ./build.sh

Builds are byte-reproducible; CI rebuilds from source and fails on any diff
against the checked-in binaries, so a PR cannot change the blobs without
matching source. Nothing at runtime depends on Zig, and nothing in the hex
package loads these binaries unless `Stevedore.Testing.runnable_image/1` is
called.
