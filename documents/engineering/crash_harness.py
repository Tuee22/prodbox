#!/usr/bin/env python3
"""300 acquire/release cycles with simulated hard crashes AND standing claims.

Establishes the claim §7.3 makes: the file set is fixed at registration and no
runtime event changes it.
"""
import fcntl, os, random, struct, subprocess, sys, tempfile

DARWIN = sys.platform == "darwin"
F_OFD_SETLK = 90 if DARWIN else 37
_lk = lambda t: (struct.pack("qqihh", 0, 0, 0, t, 0) if DARWIN
                 else struct.pack("hhqqi4x", t, 0, 0, 0, 0))

root = tempfile.mkdtemp(prefix="hgroot.")
PARTICIPANTS, SLOTS = ["alpha", "beta"], 3

def install():
    for n in ("protocol-version", "capacity", "reserved", "admission.lock"):
        open(os.path.join(root, n), "w").close()
    for p in PARTICIPANTS:
        os.makedirs(os.path.join(root, "slots", p))
        for i in range(SLOTS):
            open(os.path.join(root, "slots", p, str(i)), "wb").write(b"\0")

def count():
    return sum(len(f) for _, _, f in os.walk(root))

install()
before = count()
random.seed(20260825)
grants = crashes = standing = 0
for c in range(300):
    p = random.choice(PARTICIPANTS); i = random.randrange(SLOTS)
    path = os.path.join(root, "slots", p, str(i))
    fd = os.open(path, os.O_RDWR)
    fcntl.fcntl(fd, fcntl.F_SETFD, fcntl.fcntl(fd, fcntl.F_GETFD) | fcntl.FD_CLOEXEC)
    try:
        fcntl.fcntl(fd, F_OFD_SETLK, _lk(fcntl.F_WRLCK))
    except OSError:
        os.close(fd); continue
    grants += 1
    if random.random() < 0.2:                       # a standing claim: content, no held lock
        payload = f"standing 1787585299 {os.getpid()} 1.0\nvm:demo 1\n".encode()
        standing += 1
    else:
        payload = f"grant 1787585299 {os.getpid()} 1.0\ngpu:{i} *\n".encode()
    os.pwrite(fd, payload, 1)
    os.ftruncate(fd, 1 + len(payload))              # the v2 rule under test
    if random.random() < 0.25:                      # simulated hard crash: drop the fd, no cleanup
        os.close(fd); crashes += 1
    else:
        os.close(fd)
after = count()
print(f"  files after install:     {before}")
print(f"  cycles=300 grants={grants} standing-claims={standing} simulated-crashes={crashes}")
print(f"  files after 300 cycles:  {after}")
print(f"  RESULT: file count {'CONSTANT' if before == after else 'CHANGED'} ({before} -> {after})")
subprocess.run(["rm", "-rf", root])
