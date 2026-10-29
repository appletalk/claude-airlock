# Scratch files and pasted images

## Scratch files: `$AIRLOCK_TMP`

Write anything that must outlive a session, or that host and box both need, under
`$AIRLOCK_TMP`. Not under `/tmp`.

The box's `/tmp` is destroyed with the container (`--rm`, including on Ctrl+C) and is never
shared with the host. Anything written there is lost between sessions, and a file the host
writes in its `/tmp` is invisible to the box.

Each project gets `/tmp/airlock-<user>/<slug>` instead. It is bind-mounted into the box at
the **same path**, and both the `airlock` launcher and the host `claude` wrapper export it
as `$AIRLOCK_TMP`. So host and box name the same file identically. `airlock tmp` prints the
path (and creates it). Sessions are shared across the boundary, so both sides must agree on
where scratch lives.

- **Per project.** Only that project's own directory is mounted (mode `0700`), never the
  base and never bare `/tmp`, so nothing leaks between projects.
- **Per user.** The base is `/tmp/airlock-<user>` (`0700`), so two accounts on one host
  (you and an agent's own user, say) never share it. Anyone can create a name in a shared
  `/tmp` first, so the launcher and the `claude` wrapper refuse a default base that is a
  symlink, someone else's, or open to others. Only its owner or root can then remove it; set
  `AIRLOCK_TMP_BASE` to work around it. Once made, the base is never removed, so no one
  gets a second chance at the name.
- **`AIRLOCK_TMP_BASE` moves the base. Environment only:** the host `claude` wrapper reads
  only the environment, so a value in the config file would split host and box onto
  different directories. The launcher refuses it there.
- **An inter-session cache, not durable storage.** It lives on the host's `tmpfs`: it
  survives sessions but is cleared on reboot, so it never becomes an unmanaged junk drawer.
  Anything that must truly persist belongs in the project (gitignored if it should not be
  committed).
- **Bare `/tmp` stays ephemeral on purpose,** so `pip`, `pytest` and build temp files stay
  container-local instead of consuming the host's RAM-backed `tmpfs`.

**Upgrading from `/tmp/airlock`.** Re-source the wrapper in open terminals (or open new
ones), and let running boxes exit; until then old and new sessions name different scratch
directories. Nothing in `/tmp/airlock/<slug>` (caches, pastes) is moved. Copy what you
need into the new directory, then remove `/tmp/airlock` when no session uses it (or let a
reboot do it).

**Tell Claude about it.** Claude only follows the convention if told to. The box is
briefed automatically (`config/box-CLAUDE.md` goes into its CLAUDE.md on every launch). For **host**
Claude, paste [`config/host-CLAUDE.md`](../config/host-CLAUDE.md) into your global
`~/.claude/CLAUDE.md`.

## Pasting images into a box: `airlock paste`

**Ctrl+V of an image does not work in a box, and never will.** Claude Code reads the
clipboard by running `xclip` or `wl-paste`, and no clipboard crosses into a container
unless you mount the host's X11 or Wayland socket. That mount is what this project exists
to avoid: it would let the box read *everything* you copy, passwords included,
continuously, and on X11 also inject input into your other windows.

So the image crosses as a **file**, at a path both sides already agree on:

```
airlock paste            # save the clipboard image, print the path
alpaste                  # zsh: the same, and put the path on your clipboard
airlock paste list [N]   # recent pastes, newest first (also: alpaste list [N])
airlock paste --project DIR   # paste into another project, for this call (ignored, with a
                              #   warning, when AIRLOCK_PASTE_DIR sets a drop box)
```

Then Ctrl+V into the agent's prompt. You are pasting **text**; the agent opens the file
itself. Or say "check the latest paste" and let it list the directory.

### Where pastes go

- In `$AIRLOCK_TMP/pastes/`, as `YYYYMMDD-HHMMSSmmm.png` (host local time).
- The newest 20 are kept; older ones are pruned. All are cleared with the rest of the
  scratch directory on reboot.
- The fixed name shape makes lexical order chronological, so listing needs no `ls -t`.
- Files that do **not** match that shape are ignored by `paste list` and **never**
  pruned: the tool does not delete files it did not write.

### Setup

Set the project pastes belong to in your host config:

```
AIRLOCK_PASTE_PROJECT="$HOME/development/myproject"
```

It is **required, has no default, and is not `$PWD`.** You run `paste` from whatever
terminal is free while the agent holds the other one, so a `$PWD` default would quietly
write into a directory that box never mounts. You would hand the agent a path it cannot
open. Point it at one project and override per call with `--project DIR`. `bin/install.sh`
does not ask; it ends with a note (from a bundle too) while neither this nor
`AIRLOCK_PASTE_DIR` is set.

### Requirements

- `wl-clipboard` on Wayland or `xclip` on X11. The session decides, so XWayland picks the
  native reader.
- A PNG on the clipboard is used as is, which is the normal case on Linux desktops.
- WSLg offers **BMP only**, and the Claude API accepts PNG, JPEG, GIF and WebP. There, one
  of `imagemagick`, `ffmpeg` or `python3-pil` is needed to convert. Without one, `paste`
  fails and writes nothing rather than saving an unreadable file.
- PNG is taken first, then BMP, then JPEG, GIF, WebP or TIFF. Only those raster types: an
  SVG or other type is refused (the message names what the clipboard offered), and each is
  decoded as the type the clipboard declared, never as whatever the bytes look like. Other
  image types (`image/x-ms-bmp`, AVIF, HEIC, icons) are refused too: copy the image as PNG.
  An animated or multi-page image becomes its first frame.
- Python runs isolated (`python3 -I`), so a Pillow installed with `pip install --user` is
  not seen: install the distribution's package.
- The agents' `<command> paste` (docs/agents.md) shares this code
  (`lib/clipboard-image.sh`), so both read and convert alike.

**Every failure removes the output file.** A missing paste always means the grab failed,
never "here is an older image you are about to mistake for the new one".

### A drop box instead: `AIRLOCK_PASTE_DIR`

For an account that runs boxes but gets its pastes from someone else (an agent with a Unix
user of its own: you paste, it reads). Set `AIRLOCK_PASTE_DIR` in that account's host
config to a directory the other user writes.

- Every box mounts it **read-only** at the same path. The box finds pastes at
  `$AIRLOCK_PASTES` (otherwise `$AIRLOCK_TMP/pastes`; unset if the check failed).
- A paste dir that fails the check is not mounted; the launch warns and goes on.

The check:

- It is named by its real path and writable only by its owner (the writer).
- Every directory above it is root's and writable by root alone (so not under `/tmp`). The
  writer can change what is in it, never swap it for a link to somewhere else.
- It is checked again, and must be the same directory, right before the engine starts.
- It is not your home, inside the workspace, a protected path, or a system directory
  (`/etc`, `/usr`, `/var`, `/opt`, ...), which would cover the box's own.
- It holds no hard links or mount points when checked. What the writer adds later is
  bounded by the kernel: `fs.protected_hardlinks` lets them link only files they own or may
  write, and their FUSE mounts are closed to other users unless `/etc/fuse.conf` has
  `user_allow_other`. Either way they can only show what they could copy in.

Make it setgid with the reader's **primary** group, so new files carry that group:

```
install -d -m 2750 -o <writer> -g <reader's primary group> DIR
```

A box runs with its user's primary group only, so a supplementary group would let the
reader read pastes on the host but not in its boxes.

The writer pastes with their own tool, or with `airlock paste` and `AIRLOCK_PASTE_DIR` set
in *their* config. That writes the file group-readable (0640), but also mounts the drop box
into the writer's own boxes.
