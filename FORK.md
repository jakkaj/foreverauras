# This fork (jakkaj/foreverauras)

A fork of [neroxrw/foreverauras](https://github.com/neroxrw/foreverauras) (GPL-2.0), the most-used WeakAuras replacement
for WoW: Forever. We use it to prototype aura ideas and learn Forever's addon restrictions (secret values, the combat
API) alongside Unasphere's own addon. `origin` = this fork, `upstream` = neroxrw. `just sync-upstream` fast-forwards
main to upstream.

## Installing on the box

`just box-install` (or `tools/box-install.sh`) puts ForeverAuras at a **committed** ref (default `HEAD`;
`--ref <ref>` for another) into the gaming box's `Interface/AddOns` over ssh. `just box-diff` shows what would change
and writes nothing.

What it does, in order:
1. `git archive` of the five addon folders at the sha. Uncommitted edits are never installed (it says so).
2. Adds `ForeverAuras/Libs` from the upstream release zip pinned in `tools/libs.lock` (tag + sha256; downloaded once
   to `~/.cache/foreverauras/`, refused if the hash differs). The libraries are gitignored upstream, so this is the
   only place they come from. Bump both lines together when upstream changes its libraries.
3. Writes the sha to `ForeverAuras/.installed-sha`, so the box always says what's installed.
4. Compiles every Lua file with LuaJIT (skipping `ForeverAurasModelPaths`, one generated table over LuaJIT's
   constant limit). A syntax error stops the install before the box is touched.
5. Copies to a staging dir on the box, then rsyncs each folder into AddOns: everything except `.toc` first (with
   `--delete`, so files removed at this sha go), the `.toc` files last, so a `/reload` mid-copy never loads half an
   addon.
6. Compares the md5 of every file on the box with the local build; any difference is a failure.

It writes only `Interface/AddOns/ForeverAuras*`. It never touches `WTF/` or SavedVariables, and never starts, stops or
restarts WoW. It works while WoW runs. After a **first install** or a change that **adds a file**, WoW must be restarted
(the client only finds new addons and new files at startup); otherwise `/reload`.

Config: `FA_BOX_HOST` and `FA_BOX_WOW` (the client folder holding `Interface/`), or the `UNASPHERE_BOX_HOST` /
`UNASPHERE_BOX_WOW` already in `~/.config/unasphere/box.env` (`FA_BOX_ENV` points at another file). Host names and
paths stay out of this repo.

Needs: git, ssh with key auth to the box, curl, unzip, `luajit` (optional; skipped with a note), and rsync on the box.
