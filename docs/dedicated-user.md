# Running boxes as a dedicated user

The box is the inner wall. A Unix account of its own for the agent is an outer one: a
container or runtime escape then lands as a user who can read none of your files, keys or
sessions. The agent's work comes back to you only through what you choose to pull (git
branches, say). Nothing in the launcher assumes it runs as you.

[agents.md](agents.md) describes `make install-agents`, which sets up such accounts for
you. This page is what the launcher itself supports.

## Set up the account

- **Install per account.** Each account has its own rootless image store, so each installs
  its own copy: as the agent's user, run `bin/install.sh`. Or, to avoid giving it
  build-time network, install a [bundle](#installing-from-a-bundle) you wrote.
- **Its own config.** `~/.config/claude-airlock/config`, or a file root owns, named by
  `AIRLOCK_CONFIG` in its user manager's environment.
- **Its own Claude login.** With no network of its own: `AIRLOCK_PERSIST_LOGIN=1`, and
  `/login` inside a box, through its proxy.
- **Rootless Podman needs** subuid/subgid ranges (`usermod --add-subuids ...
  --add-subgids ...`) and a user manager (`loginctl enable-linger <user>`).
- **Lock it down.** No `sudo`, none of your groups, a locked password, and its home `0700`
  (and yours).

## What stays separate

- **Scratch is per user:** `/tmp/airlock-<user>`, refused if anyone else made it first
  (see [scratch-and-pastes.md](scratch-and-pastes.md)). A polyinstantiated `/tmp` for that
  account is better still.
- **Egress is per user.** With [airlock-envoy](https://github.com/appletalk/airlock-envoy),
  give each account its own listeners (`client <listener> <user>`). Its sockets are in
  `/run/airlock-envoy/<user>/`, which no other account may enter, and a credential belongs
  to one user's listeners only. Point the account's config at its own socket
  (`AIRLOCK_EGRESS_PROXY=/run/airlock-envoy/<user>/<listener>.sock`). The socket check
  accepts that path (root-owned directories, a service account's socket).
- **Pastes go through a drop box.** The account has no clipboard of yours. Set
  `AIRLOCK_PASTE_DIR` to a directory you write and it only reads (see
  [scratch-and-pastes.md](scratch-and-pastes.md#a-drop-box-instead-airlock_paste_dir)).
- **Files come back through git only.** Clone the repos it works on into its own home and
  have it push branches; you review and merge. Do not share a checkout you later run.
- **Reach its sessions without its password:** `machinectl shell <user>@.host` (with a
  polkit rule allowing you exactly that). A terminal multiplexer run in its user manager
  keeps sessions alive across your logouts.

## Shared directories: `AIRLOCK_EXTRA_MOUNTS`

For the operator only. Space-separated `DIR:ro` / `DIR:rw` entries, mounted at their own
paths. They come from the account's config or from the environment of whatever launches the
box (a host-side script running one box for one task); both lists apply. Never from
`.airlock/config`.

```
AIRLOCK_EXTRA_MOUNTS="/srv/queue/requests:rw /srv/queue/answers:ro"
```

Each entry must be:

- its real path;
- not a system directory or the workspace;
- owned by root or by the account itself;
- not world-writable (group-writable is fine: a queue several accounts share);
- below directories that are all root's and writable by root alone;
- free of hard-linked files and mount points.

`:rw` needs a directory root owns (in one the account owns, the box could open the mode
up). A directory named twice is mounted once, read-only if either entry says so.

Entries are checked, pinned, and checked again just before the launch (a swap stops it).
An entry that fails is skipped with a warning.

## Settings the box cannot loosen: `AIRLOCK_MANAGED_SETTINGS`

A JSON object in a file root owns and only root may write (set in the config or the
environment only). It is copied in as a Claude Code managed-settings drop-in, which
outranks the user's and the project's settings. Use it to deny tools per account, for
example:

```json
{
  "permissions": { "deny": ["SendMessage", "ListAgents"] },
  "crossSessionInbound": "refuse"
}
```

(`crossSessionInbound: refuse` stops sessions on one subscription messaging each other.)

A file that fails the check stops the launch: a box without the restrictions is not the box
you configured.

## Launch from a project folder

A box is refused when its workspace:

- is the home directory or anything above it;
- sits inside `~/.config/claude-airlock`, the install directory or `~/.local/bin`;
- holds an `AIRLOCK_CONFIG` file the account owns.

(All compared after resolving symlinks.) The workspace mount would otherwise hand the box
its own managed settings, state, config or launcher read-write. Other host config in the
home directory (shell profiles, other tools' settings) is yours to keep out of workspaces.
Subcommands (`airlock egress show`, ...) still work from anywhere.

## Installing from a bundle

A build needs the network (the Debian base, packages, the Claude Code release). An account
that should not have it, such as an agent's own user, or a host that cannot reach it, can
install what you built instead:

```
make install-airlock                              # as you, as usual
make bundle DIR=/srv/agent-inbox/airlock          # the installed version: launcher + images, ~3.5 GB
bash /srv/agent-inbox/airlock/install-bundle.sh   # as the other account: no build, no network
make bundle-clean DIR=/srv/agent-inbox/airlock    # once every reader has installed it
```

(From a checkout, `make install-bundle DIR=...` does the same.)

**What a bundle holds:**

- the installed commit's source tree;
- its images in two archives: `base` with its `os` stage, and `dev` (`podman save`; shared
  layers are stored once per archive);
- a `MANIFEST` with the commit, each image's ID and a sha256 of every file.

`make bundle` refuses unless the image tags are still the ones that commit went live with.

**What the reader checks:**

- every file against the manifest (a changed or half-written bundle installs nothing; the
  manifest is written last);
- that the source tree is the manifest's commit;
- that each image loads as exactly the ID the manifest names.

Then it goes live like any install, with the containment check, and the image smoke test
when `dev` is loaded (the smoke test runs as `dev`). The reader runs the bundle's own
installer, so launcher and images always come from one commit.

**Base-only accounts.** An account whose config has `AIRLOCK_IMAGE=claude-airlock:base`
loads only the base archive (and lets an older `dev` of its own go). It never writes the
dev image's layers, though it still checks the dev archive's sha256 with every other file.
To move it to `dev` later, set its config to `dev` and install the same bundle again; until
then a launch on `dev` says so and stops.

**Trust.** A bundle is not signed. It proves the files are the ones the writer wrote, so put
it where only the writer can write: its directory owned by the writer, every directory
above it root's.

**Space.** A bundle is a handoff, not an archive. `make bundle` replaces an earlier one in
the same directory, and `bundle-clean` removes it. Each account keeps one version of the
images (see [install.md](install.md#old-images)).

**Same engine on both sides.** Podman and docker name and number images differently, so a
bundle records its engine and a reader on the other refuses it.

**Several readers.** Each account has its own store, so each holds a copy (about 4 GB).
Write the bundle once, have each install it, then clean it.
