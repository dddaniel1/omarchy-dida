# omarchy-dida — the workspace

The repository is two things at once: it **is** the
[Dida 365](README.md) plugin, and it is the workspace the plugin was forked in.

```
manifest.json, qml/, ticktick/, bin/, tests/   the plugin — Dida365 by default
COMPARISON.md                                  what each upstream does and does not do
AGENTS.md                                      conventions for working in this repo
```

The plugin lives at the repository root on purpose: `omarchy plugin add` clones a repo
and then requires `manifest.json` **at the clone root**, so a plugin nested in a
subdirectory cannot be installed or updated through the official lifecycle. Everything
else sits beside it.

The target account is Dida365 (滴答清单, `api.dida365.com`) — the mainland-China service,
a *separate* API host from `api.ticktick.com` with separate accounts. This fork makes it
the default; the international service is still reachable with
`ticktick login --api-base https://api.ticktick.com/open/v1`.

## Upstreams (removed)

The two upstream community plugins used to be vendored here as `git subtree`s under
`sources/`. That copy was **deleted permanently** — it is gone from the repo, and only
the plugin at the repo root is installable. This table records what was imported, as the
baseline for [COMPARISON.md](COMPARISON.md):

| | siam-ticktick | sotoaugusto-ticktick |
|---|---|---|
| Upstream | <https://github.com/EhsanulHaqueSiam/omarchy-ticktick> | <https://github.com/SotoAugusto/omarchy-ticktick> |
| Branch / commit | `main` @ `4fbbbe8` | `master` @ `984fe2e` |
| Imported | 2026-10-14 | 2026-10-14 |
| License | MIT | MIT |
| Marketplace | not listed | listed (`plugins.omarchy.org`) |

Both require **Omarchy 4 (Quattro)** with the Quickshell shell — third-party plugins do
not exist on Omarchy 3.x. Both also require Python 3.11+ (standard library only).

### Comparing against an upstream

The `siam` and `soto` remotes are still configured, so upstream can be fetched without a
subtree:

```bash
git fetch siam
git diff --stat siam/main -- ticktick qml     # what upstream has since the fork
```

The plugin at the root started as an import of `siam-ticktick` and has diverged, so
upstream changes are merged by hand from that diff.

## Running the plugin in the live shell

`omarchy plugin add` clones from git. For local work, symlink this repository into the
plugin directory instead — the shell watches `~/.config/omarchy/plugins/` and hot-reloads
plugin code on save.

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/dddaniel1.dida365
omarchy-shell shell rescanPlugins   # only if a change does not take on its own
```

The installed `siam.ticktick` was signed in against Dida365 on 2026-10-14; its token
lives in `~/.config/ticktick/credentials.json` (mode `0600`) and is not affected by
swapping the plugin directory — the credential store is keyed by the account, not the
plugin.

## License and attribution

MIT. The plugin's `LICENSE` is upstream's, unchanged; [NOTICE](NOTICE) records the fork
and its modifications. The removed upstream trees carried their own MIT `LICENSE` files
and copyright notices.

Not affiliated with or endorsed by TickTick, Dida365 or Appest Inc.
