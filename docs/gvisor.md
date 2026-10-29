# gVisor (runsc)

Status: **installed, not used yet.** Boxes run under crun today. gVisor puts a user-space kernel
between the box and the host's: a kernel bug the box can reach stops being a host escape. Before
any box runs under it, each host gets a benchmark, because the cost depends on the host and on
the work (see below). The launcher option comes after that.

gVisor needs the proxy egress posture (`airlock egress proxy`, or an agent user): its network
stack has no iptables, so the firewall posture can't come up under it.

## Install and update

`bin/update-runsc` installs runsc from Google's release bucket into `/usr/local/bin`, root-owned
(the boxes' runtime must not be writable by the users who run them). It tracks the latest
release, takes the tarball (upstream stopped publishing the loose binaries), checks it against
the bucket's sha512, installs only runsc, its containerd shim and gVisor's `gvisor-bin/` helpers
(a tarball holding anything else is refused), and logs every change to
`/var/log/update-runsc.log`.

```sh
sudo bin/update-runsc            # install, update to the latest release, or repair
sudo bin/update-runsc --check    # exit 10 when an update (or a repair) is waiting
sudo bin/update-runsc --first    # install when there is none, else only --check
```

The checksum comes from the same bucket as the tarball: it shows the download is intact, not who
published it.

It never runs the installed binaries as root. What is installed is known from its record
(`/var/lib/claude-airlock/update-runsc.state`: the tarball's checksum, the release and each
file's sha256); a file that no longer matches the record, or that anyone but root can write,
counts as not installed, and the next run reinstalls it. The downloaded runsc is asked its
version as `nobody`, not as root.

It refuses while gVisor boxes are running (checked before the download and again before any
file is replaced): a box keeps the old binary open and works on, but its stop and cleanup would
run the new one against state the old one made. Stop them first (the agents' sessions:
`<command> stop`, `<command> web stop`), or pass `--force`. Boxes that are created but stopped
aren't seen; remove them before an update.

With agent users, `make install-agents` runs `update-runsc --first` (`runsc on`, the default in
`agents.conf`): it installs runsc when there is none, and otherwise only reports a waiting update;
see [agents.md](agents.md#gvisor-runsc).

## The benchmark

Run it on each host as the user whose boxes it is about (an agent user, through its shell):

```sh
make bench-runtime                 # in a checkout
bash ~/.local/share/claude-airlock/current/scripts/bench-runtime.sh    # an installed copy
```

It starts boxes the way the launcher starts a proxy-mode box and times the same work under
crun and under each gVisor platform this host can run:

| Variant | When |
|---|---|
| `crun` | always (today's runtime, the baseline) |
| `runsc-systrap` | runsc installed (gVisor's default platform) |
| `runsc-systrap-nodirectfs` | runsc installed (directfs off: slower file metadata, avoids a rootless directfs bug) |
| `runsc-kvm` | `/dev/kvm` usable by this user |
| `runsc-ptrace` | WSL (systrap is reported to fail there) |

Every runsc box runs with `ignore-cgroups` (runsc can't set up cgroups under rootless podman
yet, so a box has no per-box memory or process limit of its own; an agent user's slice limits
still hold) and `host-uds=open` (the box reaches the proxy through a host Unix socket).

The work: box start-up, a burst of 2000 short processes, git (status, log, clone, gc), a copy
and stat of many small files, node and `claude --version`, a Python venv and compileall, two
bats files and the whole suite once, pgbench, and an idle box's memory. Checks: a request
through the proxy, and a file changed on the host seen in the box. Medians of 5 runs (`--quick`:
one run, no whole suite). Expect up to an hour for every variant; `--quick` takes minutes.

Every variant gets an untimed warm-up box first, so the baseline doesn't carry the cold start.
Results go to `~/.cache/airlock-bench/<time>/`: `facts.txt` (the host) and `summary.tsv`
(medians, and how many times slower than crun) are the ones to keep. A workload that failed, or
never ran because its box died, reads FAIL; `--summarize <results.tsv>` redraws a summary.
