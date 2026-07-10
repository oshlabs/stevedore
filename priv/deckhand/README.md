# deckhand

The one who does useful work aboard: a statically linked, libc-free Linux
binary (x86_64 + aarch64) for **container diagnostics**, served by
`Stevedore.Testing.runnable_image/1`. One command core, two
frontends — a REPL that also prints unsolicited events, and a minimal
GET-only web server whose **URL space is the command set**, so an outsider
can inspect how the app inside the container sees its world.

## Invocation

    deckhand [PORT]      # REPL + server on PORT (default 8080), on 0.0.0.0 and ::

A **second instance in the same netns** finds the port taken and degrades
gracefully to REPL-only (`port N already in use (another deckhand aboard?) —
REPL-only, webserver disabled`) — deliberate, so tests can exec a second
process inside an already-running container. If only one address family's
port is taken, it serves on the other and says so.

## Commands = paths

| REPL        | HTTP           | shows                                        |
| ----------- | -------------- | -------------------------------------------- |
| `help`      | `GET /`        | this list                                    |
| `env`       | `GET /env`     | environment variables                        |
| `id`        | `GET /id`      | uid/euid/gid/egid                            |
| `hostname`  | `GET /hostname`| nodename (UTS namespace)                     |
| `uname`     | `GET /uname`   | kernel sysname/release/machine               |
| `ifaces`    | `GET /ifaces`  | interface addresses, IPv4 + IPv6             |
| `mounts`    | `GET /mounts`  | `/proc/mounts`                               |
| `cat PATH`  | `GET /cat/PATH`| one file, byte-for-byte — rootfs-content probes |
| `ls PATH`   | `GET /ls/PATH` | directory entries, `/`-suffixed for dirs (`PATH` defaults to `/`) |
| `find PATH` | `GET /find/PATH` | recursive path listing; symlinks printed, never followed |
| `ping H`    | `GET /ping/H`  | one ICMP echo; IPv4/IPv6 literal or DNS name (names prefer A, falling back to AAAA) |
| `ping6 H`   | `GET /ping6/H` | one ICMPv6 echo, forced IPv6 (AAAA only) — proves the v6 path to a dual-stack host |
| `resolve N` | `GET /resolve/N` | A + AAAA via a stub resolver (`/etc/resolv.conf`) |
| `exit`      | *(REPL only)*  | remote peers must not be able to kill the container |

Unsolicited console events: `event: resize 120x40` (SIGWINCH → `TIOCGWINSZ`,
for PTY-resize plumbing tests), `event: signal TERM` (TERM/INT also exit 0,
gracefully), `event: GET /ifaces from 172.17.0.3:54812` (every HTTP hit), and
`event: stdin closed` (EOF — the server keeps running, so `deckhand` works as
a detached container entrypoint).

Implementation notes: single-threaded `ppoll` event loop, no libc, no
allocator; unprivileged ICMP sockets with a raw-socket fallback (containers
running as root have `CAP_NET_RAW`); DNS is a deliberately minimal stub — one
UDP query to the first `nameserver`, no search domains, no TCP fallback.
`ping`/`resolve` requests block the loop for at most their 2 s timeout.

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
