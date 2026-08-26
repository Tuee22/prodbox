#!/usr/bin/env python3
"""Conformance probe for the shared host resource protocol.

Establishes, by measurement, the two things a participant cannot assume:
  * which lock family its runtime landed in (the off-diagonal cells), and
  * that a standing claim's witness is reuse-proof.

Every contended cell is preceded by a negative control on an unheld file.
"""
import ctypes, errno, fcntl, os, platform, struct, subprocess, sys, time

DARWIN = sys.platform == "darwin"
F_OFD_SETLK = 90 if DARWIN else 37


def _flock_arg(typ):
    # Darwin: off_t l_start; off_t l_len; pid_t l_pid; short l_type; short l_whence
    # Linux:  short l_type; short l_whence; off_t l_start; off_t l_len; pid_t l_pid
    # Pad to sizeof(struct flock) rather than to the pack width.
    return (struct.pack("qqihh", 0, 0, 0, typ, 0) if DARWIN
            else struct.pack("hhqqi4x", typ, 0, 0, 0, 0))


def take(fd, mech):
    if mech == "flock":
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    elif mech == "fcntl":
        fcntl.fcntl(fd, fcntl.F_SETLK, _flock_arg(fcntl.F_WRLCK))
    elif mech == "ofd":
        fcntl.fcntl(fd, F_OFD_SETLK, _flock_arg(fcntl.F_WRLCK))
    else:
        raise SystemExit(f"unknown mechanism {mech}")


def cmd_try(path, mech):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        take(fd, mech); print("ACQUIRED", flush=True)
    except OSError as e:
        print(f"BLOCKED {e.errno}", flush=True)


def cmd_hold(path, mech, secs, cloexec="set", spawn=""):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    flags = fcntl.fcntl(fd, fcntl.F_GETFD)
    if cloexec == "set":
        fcntl.fcntl(fd, fcntl.F_SETFD, flags | fcntl.FD_CLOEXEC)
    else:
        fcntl.fcntl(fd, fcntl.F_SETFD, flags & ~fcntl.FD_CLOEXEC)
    take(fd, mech)
    child = None
    if spawn:
        child = subprocess.Popen(["/bin/sleep", spawn], close_fds=False)
        print(f"SPAWNED {child.pid}", flush=True)
    print(f"HOLDING {os.getpid()}", flush=True)
    time.sleep(float(secs))


def cmd_boot():
    if DARWIN:
        out = subprocess.run(["sysctl", "-n", "kern.boottime"],
                             capture_output=True, text=True).stdout.strip()
        print(out.split("sec = ")[1].split(",")[0] if "sec = " in out else out)
    else:
        print(open("/proc/sys/kernel/random/boot_id").read().strip())


def start_time(pid):
    """The reuse-proof half of a standing claim's witness.

    A pid alone is not a witness: pids are reused. A pid plus the instant that
    exact process started is, because a reused pid belongs to a process that
    started later.
    """
    pid = int(pid)
    if DARWIN:
        import ctypes.util
        lib = ctypes.CDLL(ctypes.util.find_library("proc"))
        buf = ctypes.create_string_buffer(512)
        n = lib.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(3),
                             ctypes.c_uint64(0), buf, ctypes.c_int(512))
        if n <= 0:
            return None
        sec, usec = struct.unpack_from("<QQ", buf.raw, n - 16)
        return f"{sec}.{usec:06d}"                    # microsecond resolution
    try:
        # field 22 of /proc/<pid>/stat, in clock ticks since boot
        return open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[19]
    except (FileNotFoundError, IndexError, ProcessLookupError):
        return None


def cmd_starttime(pid):
    v = start_time(pid)
    print(v if v else "GONE")


def cmd_alive(pid, expected):
    """Honour a standing claim iff its witness still holds."""
    try:
        os.kill(int(pid), 0)
    except OSError:
        print("GONE"); return
    actual = start_time(pid)
    print("LIVE" if actual and actual == expected.strip() else "GONE")


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a: raise SystemExit(__doc__)
    {"try": lambda: cmd_try(a[1], a[2]),
     "hold": lambda: cmd_hold(a[1], a[2], a[3], *(a[4:])),
     "boot": cmd_boot,
     "starttime": lambda: cmd_starttime(a[1]),
     "alive": lambda: cmd_alive(a[1], a[2])}[a[0]]()
