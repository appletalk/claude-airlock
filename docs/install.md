# Installing, updating and signing in

The short version is in the [README](../README.md#setup). This page has the details.

## What `make install-airlock` does

`make install-airlock` (or `./bin/install.sh`):

1. writes a default host config to `~/.config/claude-airlock/config` if there is none;
2. exports the checked-out **commit** (never uncommitted edits) to
   `~/.local/share/claude-airlock/versions/<commit>/`;
3. builds `claude-airlock:base` and `:dev` from that copy;
4. only if the build succeeds, points `~/.local/share/claude-airlock/current` at it, and
   links the launcher into `~/.local/bin` through it (`airlock`, and `claude-airlock` as a
   second name for the same command);
5. runs `airlock doctor`, then the image smoke test on `:dev` (see
   [images.md](images.md#config-validators)).

The doctor stands up a real throwaway box and makes it *prove* containment: an allowed host
must be reachable and a denied host must not be. If that fails, the install says so loudly
rather than leaving you with a sandbox that isn't one. It also checks the rootless
prerequisites. Run it again any time with `make doctor` or `airlock doctor`, especially
after changing engines, rebooting or upgrading the kernel.

**The launcher never runs from your checkout.** `~/.local/bin/airlock` and the shell
integration go through `current`. Switching branches or editing files in the checkout
changes nothing until the next `make install-airlock`, and a failed build leaves the
previous version live. If an rc file still sources the zsh file, or calls the launcher,
from a checkout, the install warns: that line keeps the launcher in the working tree. Open
shells pick up a new install on their next `airlock`.

The live version and the two most recently activated others are kept. `current/VERSION`
says which commit is live. Local CA certs in `image/certs/` (untracked by design) are
copied into each install.

## Updating

Run `make install-airlock` again. Two things move on their own, and the install tracks
both.

**Claude Code.** The install resolves the current release and passes it to the base image
build, so a new release rebuilds that layer instead of reusing the cached one. The dev
image builds on the base *minus* Claude Code and copies the base's install in as its last
layer, so a release replaces one small layer there rather than rebuilding every toolchain.
To pin, or track another channel: `CLAUDE_CODE_VERSION=stable make install-airlock` (or a
specific `x.y.z`).

**Debian packages.** The build pulls the current `debian:trixie-slim` and keys the apt layer
on the ISO week. So the first install of a week refreshes every package (including
`stable-security` updates for what the base tag already carried), and the rest of the week
is a cache hit. `make refresh` forces the refresh today. `airlock doctor` shows when the
packages were last refreshed.

Unchanged upstream, same week: a cache hit that costs nothing. A refresh rebuilds
everything above the apt layer (a few minutes and a few hundred MB), which is why it is
weekly rather than daily.

### The Claude Code installer is vendored

The build runs `image/claude-install.sh`, a copy of `https://claude.ai/install.sh`, never a
script piped from the network. That script is the one download in the image nothing else
verifies (it verifies the Claude Code binary itself, against the release manifest).

The copy goes stale. Every `make install-airlock` compares it with upstream and reports
drift loudly, with `!!! INSTALLER DRIFT` lines, without failing the build. When you see
that:

```sh
make claude-installer-diff      # read what changed
make claude-installer-update    # take it; then review `git diff`, commit, make install-airlock
```

Expect this every few weeks. A stale copy keeps working until upstream changes the release
layout it fetches. Then the Claude Code layer fails to build, and the fix is the same two
commands.

### Old images

Every install moves `:base`, `:os` and `:dev` to the images it built. That leaves the
previous ones untagged (about 4 GB a rebuild, and the weekly package refresh rebuilds
everything).

Once the new version is live and has passed the containment check and the image smoke
test, the install removes the dangling images that carry claude-airlock's label, with the
layer chain only they used, and says what it freed. For example: `==> Pruned superseded
claude-airlock images: 7.2GB, 61 images and layers` (the count includes each build step's
layer).

- Other projects' images are never touched, dangling or not.
- The layers under the live images are not dangling, so an unchanged rebuild is still a
  cache hit.
- An image a running box uses stays until the next install.
- With docker's BuildKit, the build cache is kept apart from images and is not covered
  (`docker builder prune`).
- A WSL disk image does not shrink by itself when space is freed inside it. Pruning keeps it
  from growing; compacting it is still a Windows-side job.

## Signing in

### The shared token (default)

Generate a long-lived (about one year) token on the host and save it:

```sh
command claude setup-token          # copy the printed sk-ant-oat... value
printf %s 'PASTE_TOKEN' > ~/.config/claude-airlock/token
chmod 600 ~/.config/claude-airlock/token
```

One token is shared by every box. This is a **convenience for disposable boxes, not a
security tier**: logging in to each box by hand would be unusable friction.

**Billing.** The `setup-token` path uses your **subscription quota**, not pay-per-token API
credits. The TUI may show "Claude API"; that is cosmetic, so confirm with `/usage`.
**Never** set `ANTHROPIC_API_KEY` in the box: it silently switches to metered API billing.

### One project that logs itself in

For a box that is long-lived and singular (a persistent orchestrator session), the shared
token stops paying. A one-time login costs nothing there, and it yields a credential Claude
renews itself, which is what Remote Control (steering the session from your phone) needs.

The setting is per project, so every other project keeps the shared token:

```sh
cd ~/some/long-lived-project
airlock login persist     # this project only
airlock                   # complete /login once; it persists from here on
airlock login show        # confirm the mode, and whether a credential is stored
airlock login token       # switch back to the shared token
```

No token is injected, so Claude starts its normal `/login` on first launch. The credential
it writes lands in `$HOME/.claude`, which is already the persistent per-project mount, so
it survives restarts.

**This is not a security downgrade.** Both are bearer credentials for the same account via
the same OAuth flow. If anything the shared token has the wider blast radius: it is
injected into *every* box, while a persisted login exists in one.

- The mode lives in the never-mounted state dir, so a box can neither read nor change its
  own auth mode.
- `airlock login token` switches back but leaves the stored credential in place on
  purpose. It tells you where; delete it to revoke locally.
- `AIRLOCK_PERSIST_LOGIN=1` in the environment does the same for a single launch. Do not
  set it in the host config unless you mean every project.

## Telemetry is always off

Telemetry and error reporting are **off in every box**, and cannot be turned on: a sandbox
has no need to phone home.

What holds against the box is Claude Code's managed settings,
`/etc/claude-code/managed-settings.json`. They also:

- keep the auto-updater and claude.ai connectors off;
- refuse messages from your other Claude sessions (`crossSessionInbound`). Cross-session
  messaging reaches across machines over Remote Control, so any session on the account
  could otherwise steer a box. Driving the box yourself from the app over Remote Control is
  unaffected.

The launcher mounts the file read-only from the install into every box (the image carries
a copy too). Claude applies it after every settings file the box can write (its
`~/.claude`, or the workspace's `.claude/`). An empty read-only directory covers
`managed-settings.d`, so no drop-in shipped in an image can override it either.

Two fallbacks back it up, but a box can override them: `DISABLE_TELEMETRY` and
`DISABLE_ERROR_REPORTING` on the container command line, and the same keys asserted in the
box's `settings.json` at each launch.

```sh
airlock telemetry show    # always off
```

**Remote Control.** Steering a session you started on this machine works with telemetry
off on Claude Code 2.1.283 or later (2.1.154 to 2.1.282 refused it). Two Remote Control
uses still need telemetry and are not supported in a box: starting a new session onto this
machine from another device, and Remote Control under Trusted Devices.

Never set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` or `DISABLE_GROWTHBOOK` in a box you
want to steer remotely: they turn off feature-flag evaluation, which Remote Control needs.

The old `airlock telemetry on` switch is retired. A project still switched on is turned off
at its next launch, with a notice, and `make install-airlock` clears the leftover switch for
every project and lists them.

## Statusline

Boxes get `config/airlock-statusline.sh` automatically, with a green `(airlock)` badge.

To use the same line for **host** Claude, so both sides look the same apart from a red
`(host)` badge, point your host `~/.claude/settings.json` at the copy `make install-airlock`
puts in `~/.claude`, with `--host`:

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/airlock-statusline.sh --host"
}
```

Use that copy, not the checkout's `config/airlock-statusline.sh`. Host Claude runs the
status line at every refresh, so a branch or an uncommitted edit in the checkout would run
on your host. The install warns when `settings.json` points elsewhere.

The badge names whose session it is (`alice (host)`, `agent (airlock)`; in a box, the host
user the launcher passes in), so boxes of different accounts, such as an agent's own user
beside yours, are told apart.
