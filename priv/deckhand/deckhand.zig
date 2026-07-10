//! deckhand — the one who does useful work aboard.
//!
//! A statically linked, libc-free container diagnostic tool: one command
//! core, three frontends. The REPL runs the commands and prints unsolicited
//! events (console resizes, signals, HTTP hits); a minimal GET-only web
//! server mirrors the same command set as its URL space, so an outsider can
//! see how the app inside the container sees its world; and busybox-style
//! applets run a single command to completion for the run-to-completion
//! process shapes (exit with a code, echo stdin, print env, sleep and exit):
//!
//!   deckhand [PORT]        REPL + server on PORT (default 8080), 0.0.0.0 and ::
//!                          (a second instance in the same netns finds the port
//!                          taken and runs REPL-only — deliberate, so tests can
//!                          exercise a second process inside one container)
//!
//!   deckhand APPLET [ARG]  run one applet to completion — plain stdout, no
//!                          banner, no events, exit 0 (or the applet's code).
//!                          Also reached via an argv[0] symlink, busybox-style
//!                          (/bin/cat -> deckhand). An all-digits first arg is
//!                          a PORT; anything else names an applet. Every
//!                          command is an applet; cat with no PATH copies
//!                          stdin->stdout until EOF, and sleep/exit/true/false
//!                          express their result as the process exit status.
//!                          Still nothing shell-shaped (no pipes, flags,
//!                          globbing, or $VAR expansion).
//!
//!   REPL commands / HTTP paths (identical output):
//!     help      GET /            this list
//!     env       GET /env         environment variables
//!     id        GET /id          uid/gid
//!     hostname  GET /hostname    the container's nodename
//!     uname     GET /uname      kernel sysname/release/machine
//!     ifaces    GET /ifaces      interface addresses (IPv4 + IPv6)
//!     mounts    GET /mounts      /proc/mounts
//!     cat PATH  GET /cat/PATH    print one file — rootfs-content probes
//!     ls PATH   GET /ls/PATH     directory entries, "/"-suffixed for dirs
//!     find PATH GET /find/PATH   recursive path listing (no symlink follow)
//!     ping H    GET /ping/H      one ICMP echo, IPv4/IPv6 literal or DNS name
//!                                (names prefer A, falling back to AAAA)
//!     ping6 H   GET /ping6/H     one ICMPv6 echo, forced IPv6 (AAAA only) —
//!                                proves the v6 path to a dual-stack host
//!     resolve N GET /resolve/N   A + AAAA via a stub resolver (/etc/resolv.conf)
//!     sleep N   GET /sleep/N     sleep N seconds, then return
//!     true      GET /true        nothing, successfully (applet: exit 0)
//!     false     GET /false       nothing, unsuccessfully (applet: exit 1)
//!     exit [N]  (REPL/applet only — leave with status N, default 0; never
//!                over HTTP: remote peers must not be able to kill the container)
//!
//!   Applet only:
//!     await-sig           block until ANY signal arrives (no REPL, no
//!                         webserver), print its details as one line — name,
//!                         number, si_code, sender pid/uid, and for WINCH the
//!                         new console size — then exit 0. The line is the
//!                         applet's only output, so a test can assert on it
//!                         verbatim; the run-to-completion spelling of "wait
//!                         for exactly one signal".
//!
//!   Unsolicited console events:
//!     event: resize 120x40         SIGWINCH → TIOCGWINSZ (tests PTY resize plumbing)
//!     event: signal TERM           signal delivery (TERM/INT also exit 0, gracefully)
//!     event: GET /ifaces from ...  every HTTP request
//!     event: stdin closed          EOF; the server keeps running (detached containers)
//!
//! Everything is direct Linux syscalls via std.os.linux — no libc, no
//! allocator, no threads: a single ppoll event loop over stdin + signalfd +
//! the two listening sockets. NOTE: `env` over HTTP exposes the container's
//! environment (secrets included) by design — this is a test/diagnostic
//! image, never a production sidecar. Builds reproducibly with the Zig
//! version pinned in build.sh; CI rebuilds and byte-diffs the binaries.

const std = @import("std");
const linux = std.os.linux;

// ---------------------------------------------------------------------------
// tiny io runtime (raw syscalls; usize results carry -errno on failure)
// ---------------------------------------------------------------------------

fn ok(rc: usize) bool {
    return linux.errno(rc) == .SUCCESS;
}

fn wfd(fd: i32, s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const rc = linux.write(fd, s.ptr + off, s.len - off);
        if (!ok(rc) or rc == 0) return;
        off += rc;
    }
}

fn w(s: []const u8) void {
    wfd(1, s);
}

fn fmtNum(buf: []u8, n0: u64) []const u8 {
    var n = n0;
    var i: usize = buf.len;
    while (true) {
        i -= 1;
        buf[i] = @intCast('0' + n % 10);
        n /= 10;
        if (n == 0) break;
    }
    return buf[i..];
}

fn wNum(n: u64) void {
    var buf: [20]u8 = undefined;
    w(fmtNum(&buf, n));
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// --- the command sink: REPL flushes it to stdout, HTTP wraps it in a response

var out_buf: [32768]u8 = undefined;
var out_len: usize = 0;
var out_truncated = false;

fn sinkReset() void {
    out_len = 0;
    out_truncated = false;
}

fn emit(s: []const u8) void {
    const room = out_buf.len - out_len;
    if (s.len > room) {
        @memcpy(out_buf[out_len..], s[0..room]);
        out_len = out_buf.len;
        out_truncated = true;
        return;
    }
    @memcpy(out_buf[out_len..][0..s.len], s);
    out_len += s.len;
}

fn emitNum(n: u64) void {
    var buf: [20]u8 = undefined;
    emit(fmtNum(&buf, n));
}

// si_code can be negative (e.g. SI_TKILL = -6).
fn emitInt(n: i64) void {
    if (n < 0) {
        emit("-");
        emitNum(@intCast(-n));
    } else {
        emitNum(@intCast(n));
    }
}

fn sinkBody() []const u8 {
    if (out_truncated) {
        const marker = "\n[truncated]\n";
        if (out_len + marker.len > out_buf.len) out_len = out_buf.len - marker.len;
        @memcpy(out_buf[out_len..][0..marker.len], marker);
        out_len += marker.len;
        out_truncated = false;
    }
    return out_buf[0..out_len];
}

// ---------------------------------------------------------------------------
// entry + event loop
// ---------------------------------------------------------------------------

var stdin_open = true;
var line_buf: [512]u8 = undefined;
var line_len: usize = 0;

pub fn main(init: std.process.Init.Minimal) void {
    const argv = init.args.vector;

    // Busybox-style multi-call: a recognized applet name as argv[0]'s
    // basename (a symlink such as /bin/cat -> deckhand) runs that applet to
    // completion — never the REPL/server.
    if (argv.len >= 1) {
        const name = basename(std.mem.span(argv[0]));
        if (isApplet(name))
            appletMain(name, if (argv.len >= 2) std.mem.span(argv[1]) else null);
    }

    var port: u16 = 8080;
    if (argv.len >= 2) {
        const arg = std.mem.span(argv[1]);
        // Disambiguation: an all-digits first arg is a PORT (REPL + server,
        // as ever); anything else names an applet.
        if (allDigits(arg)) {
            port = parsePort(arg) orelse usageExit();
        } else if (isApplet(arg)) {
            appletMain(arg, if (argv.len >= 3) std.mem.span(argv[2]) else null);
        } else {
            usageExit();
        }
    }

    // Block the signals we watch and receive them via signalfd instead, so
    // they are just another readable fd in the poll loop.
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, .WINCH);
    linux.sigaddset(&mask, .TERM);
    linux.sigaddset(&mask, .INT);
    linux.sigaddset(&mask, .HUP);
    linux.sigaddset(&mask, .USR1);
    linux.sigaddset(&mask, .USR2);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    const sigfd: i32 = @intCast(linux.signalfd(-1, &mask, 0));

    const l4 = listen4(port);
    const l6 = listen6(port);

    w("deckhand aboard.\n");
    if (l4 != null and l6 != null) {
        w("serving GET on 0.0.0.0:");
        wNum(port);
        w(" and [::]:");
        wNum(port);
        w(" (try /help)\n");
    } else if (l4 != null or l6 != null) {
        w("serving GET on ");
        w(if (l4 != null) "0.0.0.0:" else "[::]:");
        wNum(port);
        w(" only (the other family's port is taken)\n");
    } else if (port_in_use) {
        // A second instance in the same netns is a supported way to test
        // multiple processes in one container: it just runs without the server.
        w("port ");
        wNum(port);
        w(" already in use (another deckhand aboard?) — REPL-only, webserver disabled\n");
    } else {
        w("warning: could not bind port ");
        wNum(port);
        w(", running REPL-only\n");
    }
    reportWinsize(true);
    prompt();

    var fds: [4]linux.pollfd = undefined;
    while (true) {
        var n: usize = 0;
        if (stdin_open) {
            fds[n] = .{ .fd = 0, .events = linux.POLL.IN, .revents = 0 };
            n += 1;
        }
        fds[n] = .{ .fd = sigfd, .events = linux.POLL.IN, .revents = 0 };
        n += 1;
        if (l4) |fd| {
            fds[n] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
            n += 1;
        }
        if (l6) |fd| {
            fds[n] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
            n += 1;
        }

        const rc = linux.ppoll(&fds, n, null, null);
        if (!ok(rc)) {
            if (linux.errno(rc) == .INTR) continue;
            linux.exit_group(1);
        }

        for (fds[0..n]) |pfd| {
            if (pfd.revents == 0) continue;
            if (pfd.fd == 0) handleStdin();
            if (pfd.fd == sigfd) handleSignal(sigfd);
            if (l4 != null and pfd.fd == l4.?) handleHttp(l4.?);
            if (l6 != null and pfd.fd == l6.?) handleHttp(l6.?);
        }
    }
}

fn prompt() void {
    if (stdin_open) w("> ");
}

fn handleStdin() void {
    var chunk: [256]u8 = undefined;
    const rc = linux.read(0, &chunk, chunk.len);
    if (!ok(rc)) return;
    if (rc == 0) {
        // EOF is normal for a detached container (stdin = /dev/null): note it
        // once and keep serving HTTP; only `exit` and TERM/INT stop us.
        stdin_open = false;
        if (line_len > 0) handleLine(trim(line_buf[0..line_len]));
        w("event: stdin closed (server keeps running; send SIGTERM to stop)\n");
        return;
    }
    for (chunk[0..rc]) |c| {
        if (c == '\n') {
            handleLine(trim(line_buf[0..line_len]));
            line_len = 0;
            prompt();
        } else if (line_len < line_buf.len) {
            line_buf[line_len] = c;
            line_len += 1;
        }
    }
}

// Events are composed in the (idle) sink and hit stdout as ONE write, so a
// consumer reading the console never sees a torn "event: " prefix interleaved
// with other output.
fn flushEvent() void {
    w(sinkBody());
    sinkReset();
}

// Linux signal names, indexed by signo - 1 (identical on x86_64/aarch64).
const sig_names = [_][]const u8{
    "HUP",  "INT",    "QUIT", "ILL",   "TRAP", "ABRT", "BUS",  "FPE",
    "KILL", "USR1",   "SEGV", "USR2",  "PIPE", "ALRM", "TERM", "STKFLT",
    "CHLD", "CONT",   "STOP", "TSTP",  "TTIN", "TTOU", "URG",  "XCPU",
    "XFSZ", "VTALRM", "PROF", "WINCH", "IO",   "PWR",  "SYS",
};

fn signalName(signo: u32) []const u8 {
    if (signo >= 1 and signo <= sig_names.len) return sig_names[signo - 1];
    return "?"; // realtime or out-of-range: the number is printed alongside
}

fn handleSignal(sigfd: i32) void {
    var info: linux.signalfd_siginfo = undefined;
    const rc = linux.read(sigfd, @ptrCast(&info), @sizeOf(linux.signalfd_siginfo));
    if (!ok(rc) or rc == 0) return;
    switch (info.signo) {
        @intFromEnum(linux.SIG.WINCH) => reportWinsize(false),
        @intFromEnum(linux.SIG.TERM), @intFromEnum(linux.SIG.INT) => {
            sinkReset();
            emit("event: signal ");
            emit(signalName(info.signo));
            emit(", leaving the ship\n");
            flushEvent();
            linux.exit_group(0);
        },
        else => {
            sinkReset();
            emit("event: signal ");
            emit(signalName(info.signo));
            emit("\n");
            flushEvent();
        },
    }
    prompt();
}

fn reportWinsize(initial: bool) void {
    var ws: std.posix.winsize = undefined;
    if (!readWinsize(&ws)) return; // no tty, nothing to report
    sinkReset();
    emit(if (initial) "console is " else "event: resize ");
    emitNum(ws.col);
    emit("x");
    emitNum(ws.row);
    emit("\n");
    flushEvent();
}

fn readWinsize(ws: *std.posix.winsize) bool {
    // stdout may be redirected while stdin is the tty (or vice versa); try both.
    var rc = linux.ioctl(1, linux.T.IOCGWINSZ, @intFromPtr(ws));
    if (!ok(rc)) rc = linux.ioctl(0, linux.T.IOCGWINSZ, @intFromPtr(ws));
    return ok(rc);
}

fn trim(s0: []const u8) []const u8 {
    var s = s0;
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\r')) s = s[1..];
    while (s.len > 0 and (s[s.len - 1] == ' ' or s[s.len - 1] == '\r')) s = s[0 .. s.len - 1];
    return s;
}

fn handleLine(line: []const u8) void {
    if (line.len == 0) return;
    var cmd = line;
    var arg: []const u8 = "";
    if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
        cmd = line[0..sp];
        arg = trim(line[sp + 1 ..]);
    }
    if (eq(cmd, "exit") or eq(cmd, "quit")) {
        // Applet parity: `exit N` leaves with status N — the REPL spelling
        // of a nonzero workload exit.
        var code: u32 = 0;
        if (arg.len != 0) {
            code = parseDigits(arg, 255) orelse {
                w("exit: usage: exit [N]  (N in 0-255)\n");
                return;
            };
        }
        w("going ashore.\n");
        linux.exit_group(@intCast(code));
    }
    sinkReset();
    if (!runCommand(cmd, arg)) {
        emit("unknown command: ");
        emit(cmd);
        emit(" (try 'help')\n");
    }
    w(sinkBody());
}

// ---------------------------------------------------------------------------
// applets — busybox-style multi-call: run one command to completion and exit.
// Reached via an argv[0] symlink (/bin/cat -> deckhand) or `deckhand APPLET`.
// Plain stdout, no banner, no events, not a PTY citizen. Every command is an
// applet, but nothing shell-shaped (no pipes, flags, globbing, or $VAR
// expansion); a test needing more uses a real image.
// ---------------------------------------------------------------------------

const applet_names = [_][]const u8{
    "help", "env",  "id",    "hostname", "uname", "ifaces", "mounts", "cat",   "ls",
    "find", "ping", "ping6", "resolve",  "sleep", "exit",   "true",   "false", "await-sig",
};

fn isApplet(name: []const u8) bool {
    for (applet_names) |a| if (eq(name, a)) return true;
    return false;
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn usageExit() noreturn {
    w("deckhand: usage: deckhand [PORT | APPLET [ARG]]\n");
    linux.exit_group(2);
}

// arg0 is null when no argument was given — `cat` needs that to tell stdin
// mode apart from an empty path, `exit` to default to 0. The process-exit
// shapes (exit/true/false, sleep's usage error) are handled here rather than
// in the core because only an applet has an exit status to express; signals
// also keep their default dispositions here (no signalfd), so TERM/INT kill
// a sleeping applet — same shape as coreutils sleep.
fn appletMain(name: []const u8, arg0: ?[]const u8) noreturn {
    const arg = arg0 orelse "";
    if (eq(name, "true")) linux.exit_group(0);
    if (eq(name, "false")) linux.exit_group(1);
    if (eq(name, "exit")) {
        if (arg0 == null) linux.exit_group(0); // like the shell builtin
        const code = parseDigits(arg, 255) orelse {
            w("exit: usage: exit [N]  (N in 0-255)\n");
            linux.exit_group(2);
        };
        linux.exit_group(@intCast(code));
    }
    if (eq(name, "sleep")) {
        const secs = parseDigits(arg, 100_000_000) orelse {
            w("sleep: usage: sleep SECONDS\n");
            linux.exit_group(2);
        };
        doSleep(secs);
        linux.exit_group(0);
    }
    if (eq(name, "cat") and arg0 == null) catStdin();
    if (eq(name, "await-sig")) awaitSig(arg0);
    // Everything else reuses the command core verbatim: same output as the
    // REPL and HTTP frontends.
    sinkReset();
    _ = runCommand(name, arg);
    w(sinkBody());
    linux.exit_group(0);
}

// await-sig: block until ANY signal arrives, print its details as one line —
// name, number, si_code, sender pid/uid, and for WINCH the new console
// size — then exit 0. No REPL, no webserver; the line is the applet's ONLY
// stdout output, so a test can assert on it verbatim. Applet-only by design:
// the REPL already streams signal events continuously; this is the
// run-to-completion spelling of "wait for exactly one signal". KILL/STOP
// are unblockable and never reported — they just do what they always do.
fn awaitSig(arg0: ?[]const u8) noreturn {
    if (arg0 != null) {
        w("await-sig: usage: await-sig (no arguments)\n");
        linux.exit_group(2);
    }
    var mask = linux.sigfillset();
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    const sigfd: i32 = @intCast(linux.signalfd(-1, &mask, 0));

    var info: linux.signalfd_siginfo = undefined;
    while (true) {
        const rc = linux.read(sigfd, @ptrCast(&info), @sizeOf(linux.signalfd_siginfo));
        if (ok(rc) and rc != 0) break;
        if (linux.errno(rc) != .INTR) linux.exit_group(1);
    }

    sinkReset();
    emit("event: signal ");
    emit(signalName(info.signo));
    emit(" (");
    emitNum(info.signo);
    emit(") code=");
    emitInt(info.code);
    emit(" pid=");
    emitNum(info.pid);
    emit(" uid=");
    emitNum(info.uid);
    if (info.signo == @intFromEnum(linux.SIG.WINCH)) {
        var ws: std.posix.winsize = undefined;
        if (readWinsize(&ws)) {
            emit(" resize ");
            emitNum(ws.col);
            emit("x");
            emitNum(ws.row);
        }
    }
    emit("\n");
    w(sinkBody());
    linux.exit_group(0);
}

// `cat` with no path: stdin -> stdout until EOF — the run-to-completion echo
// shape (attach/PTY handoff tests pipe through it).
fn catStdin() noreturn {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(0, &buf, buf.len);
        if (!ok(n)) {
            if (linux.errno(n) == .INTR) continue;
            linux.exit_group(1);
        }
        if (n == 0) linux.exit_group(0);
        wfd(1, buf[0..n]);
    }
}

// ---------------------------------------------------------------------------
// the command core — every command writes to the sink; HTTP mirrors this 1:1
// ---------------------------------------------------------------------------

fn runCommand(cmd: []const u8, arg: []const u8) bool {
    if (eq(cmd, "help")) {
        cmdHelp();
    } else if (eq(cmd, "env")) {
        cmdEnv();
    } else if (eq(cmd, "id")) {
        cmdId();
    } else if (eq(cmd, "hostname")) {
        cmdHostname();
    } else if (eq(cmd, "uname")) {
        cmdUname();
    } else if (eq(cmd, "ifaces")) {
        cmdIfaces();
    } else if (eq(cmd, "mounts")) {
        emitFile("/proc/mounts");
    } else if (eq(cmd, "cat")) {
        cmdCat(arg);
    } else if (eq(cmd, "ls")) {
        cmdLs(arg);
    } else if (eq(cmd, "find")) {
        cmdFind(arg);
    } else if (eq(cmd, "ping")) {
        cmdPing(arg);
    } else if (eq(cmd, "ping6")) {
        cmdPing6(arg);
    } else if (eq(cmd, "resolve")) {
        cmdResolve(arg);
    } else if (eq(cmd, "sleep")) {
        cmdSleep(arg);
    } else if (eq(cmd, "true") or eq(cmd, "false")) {
        // Nothing, (un)successfully. Only meaningful as applets, where the
        // exit status (0/1) is the point; kept in the core for parity.
    } else {
        return false;
    }
    return true;
}

// Sleeps inline: the REPL and HTTP block for the duration (single-threaded
// loop — same trade as ping's 2 s wait), making /sleep/N a delayed-response
// endpoint. This is a test image; a wedged loop is the caller's own doing.
fn cmdSleep(arg: []const u8) void {
    const secs = parseDigits(arg, 100_000_000) orelse
        return emit("sleep: usage: sleep SECONDS\n");
    doSleep(secs);
}

fn doSleep(secs: u32) void {
    var ts = linux.timespec{ .sec = @intCast(secs), .nsec = 0 };
    while (true) {
        const rc = linux.nanosleep(&ts, &ts);
        if (ok(rc) or linux.errno(rc) != .INTR) break;
    }
}

fn cmdHelp() void {
    emit(
        \\deckhand — container diagnostics. REPL command = HTTP GET path:
        \\  help      /            this list
        \\  env       /env         environment variables
        \\  id        /id          uid/gid
        \\  hostname  /hostname    nodename
        \\  uname     /uname       kernel sysname/release/machine
        \\  ifaces    /ifaces      interface addresses (IPv4 + IPv6)
        \\  mounts    /mounts      /proc/mounts
        \\  cat PATH  /cat/PATH    print one file
        \\  ls PATH   /ls/PATH     directory entries ("/" marks dirs)
        \\  find PATH /find/PATH   recursive path listing
        \\  ping H    /ping/H      one ICMP echo (IPv4/IPv6 literal or name)
        \\  ping6 H   /ping6/H     one ICMPv6 echo, forced IPv6 (AAAA only)
        \\  resolve N /resolve/N   A + AAAA via /etc/resolv.conf
        \\  sleep N   /sleep/N     sleep N seconds, then return
        \\  true      /true        nothing, successfully (applet: exit 0)
        \\  false     /false       nothing, unsuccessfully (applet: exit 1)
        \\  exit [N]               REPL only — leave with status N (default 0)
        \\every command is also an applet (argv[0] symlink or deckhand APPLET
        \\[ARG]); applet cat with no PATH copies stdin to stdout until EOF.
        \\applet only: await-sig — block until any signal (incl. WINCH), print
        \\its details as one line, exit 0
        \\
    );
}

fn cmdEnv() void {
    // /proc/self/environ is NUL-separated; rewrite to lines.
    const fd_rc = linux.openat(linux.AT.FDCWD, "/proc/self/environ", .{}, 0);
    if (!ok(fd_rc)) {
        emit("env: cannot read /proc/self/environ\n");
        return;
    }
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (!ok(n) or n == 0) break;
        for (buf[0..n]) |*c| {
            if (c.* == 0) c.* = '\n';
        }
        emit(buf[0..n]);
    }
}

fn cmdId() void {
    emit("uid=");
    emitNum(linux.getuid());
    emit(" euid=");
    emitNum(linux.geteuid());
    emit(" gid=");
    emitNum(linux.getgid());
    emit(" egid=");
    emitNum(linux.getegid());
    emit("\n");
}

fn utsField(field: [64:0]u8) []const u8 {
    const s: [*:0]const u8 = @ptrCast(&field);
    return std.mem.span(s);
}

fn cmdHostname() void {
    var uts: linux.utsname = undefined;
    if (!ok(linux.uname(&uts))) return emit("hostname: uname failed\n");
    emit(utsField(uts.nodename));
    emit("\n");
}

fn cmdUname() void {
    var uts: linux.utsname = undefined;
    if (!ok(linux.uname(&uts))) return emit("uname: failed\n");
    emit(utsField(uts.sysname));
    emit(" ");
    emit(utsField(uts.release));
    emit(" ");
    emit(utsField(uts.machine));
    emit("\n");
}

// Paths are container-absolute: the HTTP router strips the leading slash from
// /cat/etc/foo, so restore it. Empty means "/" (the ls/find default).
fn normalizePath(arg: []const u8, buf: *[512:0]u8) ?[:0]u8 {
    var len: usize = 0;
    if (arg.len == 0 or arg[0] != '/') {
        buf[0] = '/';
        len = 1;
    }
    if (arg.len + len > buf.len - 1) return null;
    @memcpy(buf[len..][0..arg.len], arg);
    len += arg.len;
    while (len > 1 and buf[len - 1] == '/') len -= 1;
    buf[len] = 0;
    return buf[0..len :0];
}

// One file to the sink — the rootfs-content probe.
fn cmdCat(arg: []const u8) void {
    if (arg.len == 0) return emit("cat: usage: cat PATH\n");
    var buf: [512:0]u8 = undefined;
    const path = normalizePath(arg, &buf) orelse return emit("cat: path too long\n");
    emitFile(path);
}

fn cmdLs(arg: []const u8) void {
    var buf: [512:0]u8 = undefined;
    const path = normalizePath(arg, &buf) orelse return emit("ls: path too long\n");
    const fd_rc = linux.openat(linux.AT.FDCWD, path, .{ .DIRECTORY = true }, 0);
    if (!ok(fd_rc)) {
        emit("ls: cannot open ");
        emit(path);
        emit("\n");
        return;
    }
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var dents: [4096]u8 = undefined;
    while (true) {
        const n = linux.getdents64(fd, &dents, dents.len);
        if (!ok(n) or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) linux.dirent64 = @ptrCast(&dents[off]);
            const name_z: [*:0]const u8 = @ptrCast(&dents[off + @offsetOf(linux.dirent64, "name")]);
            const name = std.mem.span(name_z);
            if (!eq(name, ".") and !eq(name, "..")) {
                emit(name);
                if (d.type == linux.DT.DIR) emit("/");
                emit("\n");
            }
            off += d.reclen;
        }
    }
}

// The walk path lives in one buffer (single-threaded); each recursion level
// appends "/name" and restores nothing — the base length is what matters.
var find_buf: [512:0]u8 = undefined;

fn cmdFind(arg: []const u8) void {
    const path = normalizePath(arg, &find_buf) orelse return emit("find: path too long\n");
    findWalk(path.len, 0);
}

fn findWalk(len: usize, depth: u8) void {
    emit(find_buf[0..len]);
    emit("\n");
    // Truncated output means nobody sees deeper results — stop walking. The
    // depth cap bounds stack use (each frame carries a getdents buffer).
    if (out_truncated or depth >= 12) return;
    const fd_rc = linux.openat(linux.AT.FDCWD, find_buf[0..len :0], .{ .DIRECTORY = true }, 0);
    if (!ok(fd_rc)) return; // not a directory (or unreadable): already printed
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var dents: [4096]u8 = undefined;
    while (true) {
        const n = linux.getdents64(fd, &dents, dents.len);
        if (!ok(n) or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) linux.dirent64 = @ptrCast(&dents[off]);
            const name_z: [*:0]const u8 = @ptrCast(&dents[off + @offsetOf(linux.dirent64, "name")]);
            const name = std.mem.span(name_z);
            off += d.reclen;
            if (eq(name, ".") or eq(name, "..")) continue;
            const base = if (len == 1) 0 else len; // avoid "//" under the root
            if (base + 1 + name.len > find_buf.len - 1) continue;
            find_buf[base] = '/';
            @memcpy(find_buf[base + 1 ..][0..name.len], name);
            const new_len = base + 1 + name.len;
            find_buf[new_len] = 0;
            if (d.type == linux.DT.DIR) {
                // symlinks are DT.LNK, so they are printed but never followed
                findWalk(new_len, depth + 1);
            } else {
                emit(find_buf[0..new_len]);
                emit("\n");
            }
            if (out_truncated) return;
        }
    }
}

fn emitFile(path: [*:0]const u8) void {
    const fd_rc = linux.openat(linux.AT.FDCWD, path, .{}, 0);
    if (!ok(fd_rc)) {
        emit("cannot open ");
        emit(std.mem.span(path));
        emit("\n");
        return;
    }
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (!ok(n) or n == 0) break;
        emit(buf[0..n]);
    }
}

// --- ifaces: IPv4 via the classic SIOCGIFCONF ioctl, IPv6 via /proc/net/if_inet6

const IfreqAddr = extern struct {
    name: [16]u8,
    addr: linux.sockaddr.in,
    pad: [8]u8 = undefined,
};

fn cmdIfaces() void {
    const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (ok(sock_rc)) {
        const sock: i32 = @intCast(sock_rc);
        defer _ = linux.close(sock);
        var reqs: [16]IfreqAddr = undefined;
        const Ifconf = extern struct { len: i32, ptr: usize };
        var conf = Ifconf{ .len = @sizeOf(@TypeOf(reqs)), .ptr = @intFromPtr(&reqs) };
        if (ok(linux.ioctl(sock, linux.SIOCGIFCONF, @intFromPtr(&conf)))) {
            const count = @as(usize, @intCast(conf.len)) / @sizeOf(IfreqAddr);
            for (reqs[0..count]) |req| {
                const name: [*:0]const u8 = @ptrCast(&req.name);
                emit(std.mem.span(name));
                emit(" inet ");
                emitIp4(@bitCast(req.addr.addr));
                emit("\n");
            }
        }
    }
    // /proc/net/if_inet6: "<32 hex addr> <ifindex> <plen> <scope> <flags> <name>"
    const fd_rc = linux.openat(linux.AT.FDCWD, "/proc/net/if_inet6", .{}, 0);
    if (!ok(fd_rc)) return;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const n = linux.read(fd, buf[len..].ptr, buf.len - len);
        if (!ok(n) or n == 0) break;
        len += n;
        if (len == buf.len) break;
    }
    var it = std.mem.tokenizeScalar(u8, buf[0..len], '\n');
    while (it.next()) |line| {
        var cols = std.mem.tokenizeScalar(u8, line, ' ');
        const hex = cols.next() orelse continue;
        if (hex.len != 32) continue;
        _ = cols.next(); // ifindex
        _ = cols.next(); // prefix len
        _ = cols.next(); // scope
        _ = cols.next(); // flags
        const name = cols.next() orelse continue;
        var addr: [16]u8 = undefined;
        var valid = true;
        for (0..16) |i| {
            addr[i] = (hexNibble(hex[i * 2]) orelse {
                valid = false;
                break;
            }) << 4 | (hexNibble(hex[i * 2 + 1]) orelse {
                valid = false;
                break;
            });
        }
        if (!valid) continue;
        emit(name);
        emit(" inet6 ");
        emitIp6(addr);
        emit("\n");
    }
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// --- address parsing / formatting ---

fn emitIp4(addr: [4]u8) void {
    for (addr, 0..) |b, i| {
        if (i > 0) emit(".");
        emitNum(b);
    }
}

fn emitIp6(addr: [16]u8) void {
    // RFC 5952-ish: compress the longest run (>= 2) of zero groups as "::".
    var groups: [8]u16 = undefined;
    for (0..8) |i| groups[i] = (@as(u16, addr[i * 2]) << 8) | addr[i * 2 + 1];
    var best_start: usize = 8;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (groups[i] != 0) continue;
        var j = i;
        while (j < 8 and groups[j] == 0) j += 1;
        if (j - i > best_len) {
            best_len = j - i;
            best_start = i;
        }
        i = j;
    }
    if (best_len < 2) best_start = 8;
    i = 0;
    var hex: [4]u8 = undefined;
    while (i < 8) {
        if (i == best_start) {
            emit("::");
            i += best_len;
            continue;
        }
        if (i > 0 and i != best_start + best_len) emit(":");
        var n: usize = 0;
        var started = false;
        for ([4]u4{ 12, 8, 4, 0 }) |shift| {
            const nib: u4 = @truncate(groups[i] >> shift);
            if (nib == 0 and !started and shift != 0) continue;
            started = true;
            hex[n] = "0123456789abcdef"[nib];
            n += 1;
        }
        emit(hex[0..n]);
        i += 1;
    }
    if (best_start == 0 and best_len == 8) return; // "::" already emitted
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn parseDigits(s: []const u8, max: u32) ?u32 {
    if (!allDigits(s)) return null;
    var n: u32 = 0;
    for (s) |c| {
        n = n * 10 + (c - '0');
        if (n > max) return null;
    }
    return n;
}

fn parsePort(s: []const u8) ?u16 {
    const n = parseDigits(s, 65535) orelse return null;
    if (n == 0) return null;
    return @intCast(n);
}

fn parseIp4(s: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var octet: u32 = 0;
    var digits: usize = 0;
    var idx: usize = 0;
    for (s) |c| {
        if (c == '.') {
            if (digits == 0 or idx >= 3) return null;
            out[idx] = @intCast(octet);
            idx += 1;
            octet = 0;
            digits = 0;
        } else if (c >= '0' and c <= '9') {
            octet = octet * 10 + (c - '0');
            digits += 1;
            if (octet > 255 or digits > 3) return null;
        } else return null;
    }
    if (idx != 3 or digits == 0) return null;
    out[3] = @intCast(octet);
    return out;
}

fn parseIp6(s: []const u8) ?[16]u8 {
    if (std.mem.indexOfScalar(u8, s, ':') == null) return null;
    // Split once on the "::" gap; each side is then plain colon-separated groups.
    var head: []const u8 = s;
    var tail: []const u8 = "";
    var has_gap = false;
    if (std.mem.indexOf(u8, s, "::")) |gap| {
        has_gap = true;
        head = s[0..gap];
        tail = s[gap + 2 ..];
        if (std.mem.indexOf(u8, tail, "::") != null) return null;
    }
    var groups: [8]u16 = @splat(0);
    var hn: usize = 0;
    if (!parseIp6Groups(head, &groups, &hn)) return null;
    var tg: [8]u16 = @splat(0);
    var tn: usize = 0;
    if (!parseIp6Groups(tail, &tg, &tn)) return null;
    if (has_gap) {
        if (hn + tn > 7) return null;
        for (0..tn) |k| groups[8 - tn + k] = tg[k];
    } else if (hn != 8) {
        return null;
    }
    var out: [16]u8 = undefined;
    for (0..8) |k| {
        out[k * 2] = @intCast(groups[k] >> 8);
        out[k * 2 + 1] = @intCast(groups[k] & 0xff);
    }
    return out;
}

fn parseIp6Groups(s: []const u8, groups: *[8]u16, n: *usize) bool {
    if (s.len == 0) return true;
    var it = std.mem.splitScalar(u8, s, ':');
    while (it.next()) |part| {
        if (part.len == 0 or part.len > 4 or n.* >= 8) return false;
        var val: u32 = 0;
        for (part) |c| val = val * 16 + (hexNibble(c) orelse return false);
        groups[n.*] = @intCast(val);
        n.* += 1;
    }
    return true;
}

// ---------------------------------------------------------------------------
// http: two GET-only listeners; the URL space is the command set
// ---------------------------------------------------------------------------

// Whether any bind failed with EADDRINUSE — the second-instance signature.
var port_in_use = false;

fn bindListen(fd: i32, addr: *const linux.sockaddr, len: linux.socklen_t) ?i32 {
    const rc = linux.bind(fd, addr, len);
    if (!ok(rc)) {
        if (linux.errno(rc) == .ADDRINUSE) port_in_use = true;
        _ = linux.close(fd);
        return null;
    }
    if (!ok(linux.listen(fd, 8))) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

fn listen4(port: u16) ?i32 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (!ok(rc)) return null;
    const fd: i32 = @intCast(rc);
    reuseAddr(fd);
    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    return bindListen(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
}

fn listen6(port: u16) ?i32 {
    const rc = linux.socket(linux.AF.INET6, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (!ok(rc)) return null;
    const fd: i32 = @intCast(rc);
    reuseAddr(fd);
    // V6ONLY so this socket doesn't claim the v4-mapped space the 0.0.0.0
    // listener already owns (dual binding would fail with EADDRINUSE).
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.IPV6, linux.IPV6.V6ONLY, @ptrCast(&one), 4);
    var addr = linux.sockaddr.in6{
        .port = std.mem.nativeToBig(u16, port),
        .flowinfo = 0,
        .addr = @splat(0),
        .scope_id = 0,
    };
    return bindListen(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
}

fn reuseAddr(fd: i32) void {
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
}

fn handleHttp(listen_fd: i32) void {
    var ss: linux.sockaddr.storage = undefined;
    var slen: linux.socklen_t = @sizeOf(@TypeOf(ss));
    const rc = linux.accept(listen_fd, @ptrCast(&ss), &slen);
    if (!ok(rc)) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);

    // One bounded read after a short poll: a GET request line fits in one
    // packet in practice, and a stalled client must not wedge the event loop.
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    var ts = linux.timespec{ .sec = 2, .nsec = 0 };
    if (!ok(linux.ppoll(&pfd, 1, &ts, null)) or pfd[0].revents == 0) return;
    var req: [2048]u8 = undefined;
    const n = linux.read(fd, &req, req.len);
    if (!ok(n) or n == 0) return;

    var line = req[0..n];
    if (std.mem.indexOfScalar(u8, line, '\r')) |cr| line = line[0..cr];
    if (std.mem.indexOfScalar(u8, line, '\n')) |lf| line = line[0..lf];

    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    const method = parts.next() orelse return;
    const raw_path = parts.next() orelse "/";

    sinkReset();
    emit("event: ");
    emit(method);
    emit(" ");
    emit(raw_path);
    emit(" from ");
    emitPeer(&ss);
    emit("\n");
    flushEvent();
    prompt();

    if (!eq(method, "GET")) {
        respond(fd, "405 Method Not Allowed", "GET only. This is a small ship.\n");
        return;
    }

    var path = raw_path;
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    if (path.len > 0 and path[0] == '/') path = path[1..];

    var cmd = path;
    var arg: []const u8 = "";
    if (std.mem.indexOfScalar(u8, path, '/')) |sl| {
        cmd = path[0..sl];
        arg = path[sl + 1 ..];
    }
    if (cmd.len == 0) cmd = "help";

    sinkReset();
    if (eq(cmd, "exit") or eq(cmd, "quit") or !runCommand(cmd, arg)) {
        sinkReset();
        emit("no such path. ");
        cmdHelp();
        respond(fd, "404 Not Found", sinkBody());
        return;
    }
    respond(fd, "200 OK", sinkBody());
}

fn respond(fd: i32, status: []const u8, body: []const u8) void {
    var head: [128]u8 = undefined;
    var num: [20]u8 = undefined;
    var len: usize = 0;
    for ([_][]const u8{
        "HTTP/1.1 ",                                        status,
        "\r\nContent-Type: text/plain\r\nContent-Length: ", fmtNum(&num, body.len),
        "\r\nConnection: close\r\n\r\n",
    }) |part| {
        @memcpy(head[len..][0..part.len], part);
        len += part.len;
    }
    wfd(fd, head[0..len]);
    wfd(fd, body);
}

fn emitPeer(ss: *const linux.sockaddr.storage) void {
    switch (ss.family) {
        linux.AF.INET => {
            const a: *const linux.sockaddr.in = @ptrCast(@alignCast(ss));
            emitIp4(@bitCast(a.addr));
            emit(":");
            emitNum(std.mem.bigToNative(u16, a.port));
        },
        linux.AF.INET6 => {
            const a: *const linux.sockaddr.in6 = @ptrCast(@alignCast(ss));
            emit("[");
            emitIp6(a.addr);
            emit("]:");
            emitNum(std.mem.bigToNative(u16, a.port));
        },
        else => emit("?"),
    }
}

// ---------------------------------------------------------------------------
// resolve: a minimal stub resolver — /etc/resolv.conf, one UDP query, 2s wait
// ---------------------------------------------------------------------------

const QTYPE_A: u16 = 1;
const QTYPE_AAAA: u16 = 28;

fn cmdResolve(name: []const u8) void {
    if (name.len == 0) return emit("resolve: usage: resolve NAME\n");
    var any = false;
    var a4: [4][4]u8 = undefined;
    const n4 = dnsQuery(name, QTYPE_A, &a4, null);
    for (a4[0..n4]) |addr| {
        emit("A ");
        emitIp4(addr);
        emit("\n");
        any = true;
    }
    var a6: [4][16]u8 = undefined;
    const n6 = dnsQuery(name, QTYPE_AAAA, null, &a6);
    for (a6[0..n6]) |addr| {
        emit("AAAA ");
        emitIp6(addr);
        emit("\n");
        any = true;
    }
    if (!any) {
        emit("resolve: no answer for ");
        emit(name);
        emit("\n");
    }
}

// Returns the nameserver as a sockaddr ready to connect to (port 53).
fn nameserver(ss: *linux.sockaddr.storage) ?linux.socklen_t {
    const fd_rc = linux.openat(linux.AT.FDCWD, "/etc/resolv.conf", .{}, 0);
    if (!ok(fd_rc)) return null;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (!ok(n) or n == 0) return null;
    var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        var cols = std.mem.tokenizeAny(u8, line, " \t");
        const key = cols.next() orelse continue;
        if (!eq(key, "nameserver")) continue;
        const val = cols.next() orelse continue;
        if (parseIp4(val)) |a4| {
            const sa: *linux.sockaddr.in = @ptrCast(@alignCast(ss));
            sa.* = .{ .port = std.mem.nativeToBig(u16, 53), .addr = @bitCast(a4) };
            return @sizeOf(linux.sockaddr.in);
        }
        if (parseIp6(val)) |a6| {
            const sa: *linux.sockaddr.in6 = @ptrCast(@alignCast(ss));
            sa.* = .{
                .port = std.mem.nativeToBig(u16, 53),
                .flowinfo = 0,
                .addr = a6,
                .scope_id = 0,
            };
            return @sizeOf(linux.sockaddr.in6);
        }
    }
    return null;
}

fn dnsQuery(name: []const u8, qtype: u16, out4: ?*[4][4]u8, out6: ?*[4][16]u8) usize {
    var ss: linux.sockaddr.storage = undefined;
    const slen = nameserver(&ss) orelse return 0;

    var pkt: [512]u8 = undefined;
    var id: [2]u8 = .{ 0xde, 0xcc };
    _ = linux.getrandom(&id, 2, 0);
    // Header: id, RD=1, one question. RFC 1035 §4.1.1.
    pkt[0] = id[0];
    pkt[1] = id[1];
    pkt[2] = 0x01; // RD
    pkt[3] = 0;
    pkt[4] = 0;
    pkt[5] = 1; // QDCOUNT
    @memset(pkt[6..12], 0);
    var p: usize = 12;
    // QNAME as length-prefixed labels. RFC 1035 §3.1.
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or p + label.len + 1 > pkt.len - 6) return 0;
        pkt[p] = @intCast(label.len);
        @memcpy(pkt[p + 1 ..][0..label.len], label);
        p += 1 + label.len;
    }
    pkt[p] = 0;
    p += 1;
    pkt[p] = @intCast(qtype >> 8);
    pkt[p + 1] = @intCast(qtype & 0xff);
    pkt[p + 2] = 0;
    pkt[p + 3] = 1; // IN
    p += 4;

    const domain: u32 = if (slen == @sizeOf(linux.sockaddr.in)) linux.AF.INET else linux.AF.INET6;
    const sock_rc = linux.socket(domain, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (!ok(sock_rc)) return 0;
    const sock: i32 = @intCast(sock_rc);
    defer _ = linux.close(sock);
    if (!ok(linux.sendto(sock, &pkt, p, 0, @ptrCast(&ss), slen))) return 0;

    var pfd = [1]linux.pollfd{.{ .fd = sock, .events = linux.POLL.IN, .revents = 0 }};
    var ts = linux.timespec{ .sec = 2, .nsec = 0 };
    if (!ok(linux.ppoll(&pfd, 1, &ts, null)) or pfd[0].revents == 0) return 0;

    var resp: [1024]u8 = undefined;
    const rn = linux.recvfrom(sock, &resp, resp.len, 0, null, null);
    if (!ok(rn) or rn < 12) return 0;
    const r = resp[0..rn];
    if (r[0] != pkt[0] or r[1] != pkt[1]) return 0;
    const ancount = (@as(u16, r[6]) << 8) | r[7];

    var pos: usize = 12;
    pos = skipName(r, pos) orelse return 0;
    if (pos + 4 > r.len) return 0;
    pos += 4; // qtype + qclass

    var found: usize = 0;
    var i: u16 = 0;
    while (i < ancount and found < 4) : (i += 1) {
        pos = skipName(r, pos) orelse return found;
        if (pos + 10 > r.len) return found;
        const rtype = (@as(u16, r[pos]) << 8) | r[pos + 1];
        const rdlen = (@as(u16, r[pos + 8]) << 8) | r[pos + 9];
        pos += 10;
        if (pos + rdlen > r.len) return found;
        if (rtype == qtype and qtype == QTYPE_A and rdlen == 4) {
            @memcpy(&out4.?[found], r[pos..][0..4]);
            found += 1;
        } else if (rtype == qtype and qtype == QTYPE_AAAA and rdlen == 16) {
            @memcpy(&out6.?[found], r[pos..][0..16]);
            found += 1;
        }
        pos += rdlen;
    }
    return found;
}

// Skips a possibly-compressed DNS name (RFC 1035 §4.1.4): a pointer ends it.
fn skipName(r: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < r.len) {
        const len = r[pos];
        if (len == 0) return pos + 1;
        if (len & 0xc0 == 0xc0) return if (pos + 2 <= r.len) pos + 2 else null;
        pos += 1 + len;
    }
    return null;
}

// ---------------------------------------------------------------------------
// ping: one echo, IPv4 or IPv6, unprivileged ICMP socket with raw fallback
// ---------------------------------------------------------------------------

fn cmdPing(host: []const u8) void {
    if (host.len == 0) return emit("ping: usage: ping HOST\n");
    if (parseIp4(host)) |a4| return ping4(a4);
    if (parseIp6(host)) |a6| return ping6(a6);
    var out4: [4][4]u8 = undefined;
    if (dnsQuery(host, QTYPE_A, &out4, null) > 0) {
        emit("resolved ");
        emit(host);
        emit(" to ");
        emitIp4(out4[0]);
        emit("\n");
        return ping4(out4[0]);
    }
    var out6: [4][16]u8 = undefined;
    if (dnsQuery(host, QTYPE_AAAA, null, &out6) > 0) {
        emit("resolved ");
        emit(host);
        emit(" to ");
        emitIp6(out6[0]);
        emit("\n");
        return ping6(out6[0]);
    }
    emit("ping: cannot resolve ");
    emit(host);
    emit("\n");
}

// Forced IPv6: proves the v6 path to a dual-stack host, which plain `ping`
// can't (it prefers A for names and would silently succeed over v4).
fn cmdPing6(host: []const u8) void {
    if (host.len == 0) return emit("ping6: usage: ping6 HOST\n");
    if (parseIp6(host)) |a6| return ping6(a6);
    if (parseIp4(host) != null) return emit("ping6: not an IPv6 destination\n");
    var out6: [4][16]u8 = undefined;
    if (dnsQuery(host, QTYPE_AAAA, null, &out6) > 0) {
        emit("resolved ");
        emit(host);
        emit(" to ");
        emitIp6(out6[0]);
        emit("\n");
        return ping6(out6[0]);
    }
    emit("ping6: no AAAA record for ");
    emit(host);
    emit("\n");
}

fn nowUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

fn icmpSocket(domain: u32, proto: u32) ?struct { fd: i32, raw: bool } {
    // Unprivileged ping sockets first (net.ipv4.ping_group_range); raw needs
    // CAP_NET_RAW, which container roots typically have.
    var rc = linux.socket(domain, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, proto);
    if (ok(rc)) return .{ .fd = @intCast(rc), .raw = false };
    rc = linux.socket(domain, linux.SOCK.RAW | linux.SOCK.CLOEXEC, proto);
    if (ok(rc)) return .{ .fd = @intCast(rc), .raw = true };
    return null;
}

fn icmpChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) sum += (@as(u32, data[i]) << 8) | data[i + 1];
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @intCast(~sum & 0xffff);
}

fn buildEcho(pkt: *[16]u8, icmp_type: u8, with_checksum: bool) void {
    pkt.* = .{ icmp_type, 0, 0, 0, 0, 0xdd, 0, 1 } ++ "deckhand".*;
    if (with_checksum) {
        const ck = icmpChecksum(pkt);
        pkt[2] = @intCast(ck >> 8);
        pkt[3] = @intCast(ck & 0xff);
    }
}

fn pingWait(fd: i32, raw_v4: bool, reply_type: u8, started: u64) void {
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    var ts = linux.timespec{ .sec = 2, .nsec = 0 };
    if (!ok(linux.ppoll(&pfd, 1, &ts, null)) or pfd[0].revents == 0) {
        emit("no reply within 2s\n");
        return;
    }
    var buf: [256]u8 = undefined;
    const n = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
    if (!ok(n) or n == 0) return emit("ping: receive failed\n");
    var payload = buf[0..n];
    if (raw_v4) {
        // Raw IPv4 sockets deliver the IP header too; ICMP dgram and ICMPv6 don't.
        if (payload.len < 20) return emit("ping: short reply\n");
        const ihl: usize = @as(usize, payload[0] & 0x0f) * 4;
        if (payload.len <= ihl) return emit("ping: short reply\n");
        payload = payload[ihl..];
    }
    if (payload.len < 1 or payload[0] != reply_type) {
        emit("ping: unexpected reply type\n");
        return;
    }
    const us = nowUs() - started;
    emit("reply: time=");
    emitNum(us / 1000);
    emit(".");
    emitNum(us % 1000 / 100);
    emit(" ms\n");
}

fn ping4(addr: [4]u8) void {
    const sock = icmpSocket(linux.AF.INET, linux.IPPROTO.ICMP) orelse {
        emit("ping: not permitted (needs CAP_NET_RAW or ping sockets enabled)\n");
        return;
    };
    defer _ = linux.close(sock.fd);
    var pkt: [16]u8 = undefined;
    buildEcho(&pkt, 8, true); // echo request, RFC 792
    var sa = linux.sockaddr.in{ .port = 0, .addr = @bitCast(addr) };
    const started = nowUs();
    if (!ok(linux.sendto(sock.fd, &pkt, pkt.len, 0, @ptrCast(&sa), @sizeOf(@TypeOf(sa)))))
        return emit("ping: send failed\n");
    emit("ping ");
    emitIp4(addr);
    emit(": ");
    pingWait(sock.fd, sock.raw, 0, started); // echo reply
}

fn ping6(addr: [16]u8) void {
    const sock = icmpSocket(linux.AF.INET6, linux.IPPROTO.ICMPV6) orelse {
        emit("ping: not permitted (needs CAP_NET_RAW or ping sockets enabled)\n");
        return;
    };
    defer _ = linux.close(sock.fd);
    var pkt: [16]u8 = undefined;
    buildEcho(&pkt, 128, false); // echo request, RFC 4443; kernel computes the checksum
    var sa = linux.sockaddr.in6{ .port = 0, .flowinfo = 0, .addr = addr, .scope_id = 0 };
    const started = nowUs();
    if (!ok(linux.sendto(sock.fd, &pkt, pkt.len, 0, @ptrCast(&sa), @sizeOf(@TypeOf(sa)))))
        return emit("ping: send failed\n");
    emit("ping ");
    emitIp6(addr);
    emit(": ");
    pingWait(sock.fd, false, 129, started); // echo reply
}
