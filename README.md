# omarchy-dida

A workspace for a **Dida365 / TickTick** bar plugin for [Omarchy](https://omarchy.org/),
starting from the two community plugins that already exist.

Status: **research and comparison.** Neither upstream is modified yet — they are
vendored here verbatim so they can be read side by side, run, and diffed.

The target account is Dida365 (滴答清单, `api.dida365.com`) — the mainland-China
service, which is a *separate* API host from `api.ticktick.com` and needs an
explicit `--api-base` at sign-in.

## Layout

```
sources/
├── siam-ticktick/         EhsanulHaqueSiam/omarchy-ticktick   (plugin id siam.ticktick)
└── sotoaugusto-ticktick/  SotoAugusto/omarchy-ticktick        (plugin id io.github.sotoaugusto.ticktick)
COMPARISON.md              feature/architecture comparison, gaps, candidate directions
AGENTS.md                  conventions for working in this repo
```

Each `sources/` tree is a `git subtree`: the upstream history is part of this repo's
history, so `git log -- sources/siam-ticktick` shows the real upstream commits and a
later `git subtree pull` can bring in updates.

## Vendored upstreams

| | siam-ticktick | sotoaugusto-ticktick |
|---|---|---|
| Upstream | <https://github.com/EhsanulHaqueSiam/omarchy-ticktick> | <https://github.com/SotoAugusto/omarchy-ticktick> |
| Branch / commit | `main` @ `4fbbbe8` | `master` @ `984fe2e` |
| Imported | 2026-10-14 | 2026-10-14 |
| License | MIT | MIT |
| Marketplace | not listed | listed (`plugins.omarchy.org`) |

Both require **Omarchy 4 (Quattro)** with the Quickshell shell — third-party plugins do
not exist on Omarchy 3.x. Both also require Python 3.11+ (standard library only).

## Refreshing an upstream

Upstreams are registered as remotes, so a pull is one command:

```bash
git subtree pull --prefix=sources/siam-ticktick siam main
git subtree pull --prefix=sources/sotoaugusto-ticktick soto master
```

## Running a tree in the live shell

`omarchy plugin add` clones from git; for local work, symlink a tree into the plugin
directory instead. Plugin code hot-reloads on save, and the shell watches
`~/.config/omarchy/plugins/`.

```bash
# replace the installed copy with a link to this repo (make a backup first)
rm -rf ~/.config/omarchy/plugins/siam.ticktick
ln -s "$PWD/sources/siam-ticktick" ~/.config/omarchy/plugins/siam.ticktick

# force a reload if a change does not take
omarchy-shell shell rescanPlugins
```

The installed `siam.ticktick` was signed in against Dida365 on 2026-10-14; its token
lives in `~/.config/ticktick/credentials.json` (mode `0600`) and is not affected by
swapping the plugin directory.

## License and attribution

This repo is MIT. The vendored trees keep their own upstream MIT `LICENSE` files and
copyright notices, and are not affiliated with or endorsed by TickTick or Appest Inc.
