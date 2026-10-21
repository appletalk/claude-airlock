"""The box's seccomp profile, by behaviour: run as dev inside a box (image-smoke.sh).

Each refused call must fail, whichever way it is asked (high bits in an argument, a 32-bit
or x32 syscall), and the everyday ones must still work. Exits 1 if any check fails.
"""
import ctypes, errno, os, platform, signal, socket, mmap

libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
fails = 0


def report(ok, what, got):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + f"{what}: {got}")
    fails += not ok


def sc(nr, *args):
    r = libc.syscall(ctypes.c_long(nr), *[ctypes.c_long(a) for a in args])
    return r, ctypes.get_errno()


def refused(what, nr, *args):
    r, e = sc(nr, *args)
    if r >= 0:
        os.close(r) if nr in (41, 53) else None
    report(r < 0, what + " refused", f"rc={r} {errno.errorcode.get(e, e) if r < 0 else 'allowed'}")


def killed(what, fn):
    """fn runs in a child, which seccomp must kill (SIGSYS) rather than let return."""
    pid = os.fork()
    if pid == 0:
        try:
            fn()
        finally:
            os._exit(0)
    _, st = os.waitpid(pid, 0)
    sig = os.WTERMSIG(st) if os.WIFSIGNALED(st) else None
    report(sig == signal.SIGSYS, what + " kills the process", f"signal={sig} exit={os.WEXITSTATUS(st) if sig is None else '-'}")


if platform.machine() != "x86_64":
    print(f"  skip  seccomp checks are written for x86_64, not {platform.machine()}")
    raise SystemExit(0)

AF_ALG, AF_VSOCK, AF_PACKET, SEQPACKET, STREAM = 38, 40, 17, 5, 1
refused("keyctl", 250, 0, -3, 0)
refused("add_key", 248, 0, 0, 0, 0, 0)
refused("request_key", 249, 0, 0, 0, 0)
refused("memfd_secret", 447, 0)
refused("unshare(CLONE_NEWUSER)", 272, 0x10000000)
refused("socket(AF_ALG)", 41, AF_ALG, SEQPACKET, 0)
refused("socket(AF_ALG | 1<<32)", 41, AF_ALG | (1 << 32), SEQPACKET, 0)
refused("socket(AF_INET | 1<<32)", 41, socket.AF_INET | (1 << 32), STREAM, 0)
refused("socket(AF_VSOCK)", 41, AF_VSOCK, STREAM, 0)
refused("socket(AF_PACKET)", 41, AF_PACKET, 3, 0)
refused("socketpair(AF_ALG)", 53, AF_ALG, SEQPACKET, 0, ctypes.addressof(ctypes.c_int(0)))
killed("x32 socket(AF_ALG)", lambda: sc(0x40000000 | 41, AF_ALG, SEQPACKET, 0))


def ia32_getpid():
    # mov eax, 20 (i386 getpid); int 0x80; ret
    code = bytes.fromhex("b814000000cd80c3")
    m = mmap.mmap(-1, len(code), prot=mmap.PROT_READ | mmap.PROT_WRITE | mmap.PROT_EXEC)
    m.write(code)
    ctypes.CFUNCTYPE(ctypes.c_int)(ctypes.addressof(ctypes.c_char.from_buffer(m)))()


killed("a 32-bit syscall (int 0x80)", ia32_getpid)

for fam, typ, name in ((socket.AF_UNIX, STREAM, "AF_UNIX"), (socket.AF_INET, STREAM, "AF_INET"),
                       (socket.AF_INET6, STREAM, "AF_INET6"), (socket.AF_NETLINK, socket.SOCK_RAW, "AF_NETLINK route")):
    try:
        socket.socket(fam, typ, 0).close()
        report(True, f"socket({name}) works", "ok")
    except OSError as ex:
        report(False, f"socket({name}) works", errno.errorcode.get(ex.errno, ex.errno))
try:
    a, b = socket.socketpair()
    a.close(); b.close()
    report(True, "socketpair(AF_UNIX) works", "ok")
except OSError as ex:
    report(False, "socketpair(AF_UNIX) works", errno.errorcode.get(ex.errno, ex.errno))
report(os.memfd_create("x") >= 0, "memfd_create works", "ok")
raise SystemExit(1 if fails else 0)
