# 2026-09-23: Repology → direct nix eval for package-update checks

Affects: [`modules/nix-info.nix`](../../modules/nix-info.nix) (systemPackages),
[`modules/nix-profile-info.nix`](../../modules/nix-profile-info.nix) (`nix profile`).

## What changed

Both "is a newer version available" collectors used to query the
[Repology](https://repology.org) public API to compare installed package versions
against upstream. Both were rewritten to instead evaluate the tracked nixpkgs
channel directly with `nix eval` and compare against that.

## Why

Trigger: on 2026-09-23, repology.org became permanently unreachable — the domain's
registrar suspended it (DNS A record resolved to `127.0.0.1`, TCP connections
refused outright). This wasn't a rate limit; the domain itself had lapsed. The
systemPackages-side collector was reporting all 217 tracked packages as "untracked"
as a result.

But Repology had two problems independent of that outage, which is why the fix was
"stop depending on it" rather than "wait for it to come back":

- **Name-matching was unreliable.** Repology indexes by upstream *project* name,
  which doesn't always match a package's nixpkgs `pname`. Niche or self-maintained
  packages (`rtk`, `llmfit`) aren't tracked by Repology at all, so they never
  appeared in the update check regardless of whether nixpkgs had a newer version.
- **The reported version was Repology's crawl of upstream, not what nixpkgs would
  actually give you.** A package can be "outdated" per Repology while nixpkgs
  hasn't picked up the new version yet (or vice versa) — the two numbers can
  legitimately disagree, and only one of them (nixpkgs') is actionable via
  `nix flake update`.

Evaluating the nixpkgs channel directly (`github:NixOS/nixpkgs/<ref>#legacyPackages.x86_64-linux`)
fixes both: the version compared against is exactly what a `flake update` would pull
in, and there's no external service whose availability the metric depends on.

## Why this was previously considered impractical, and what made it work now

Directly evaluating "does nixpkgs have a newer version of every installed package"
was avoided earlier because attribute names aren't known ahead of time and a naive
per-package `nix eval` doesn't scale:

- **`nix profile` side (measured 4 elements)**: this scale problem doesn't apply —
  `manifest.json` already records each element's own `originalUrl` and `attrPath`,
  so each package is one `nix eval --raw '<url>#<attrPath>.version'` call, measured
  ~0.3s per call with a warm store. No search needed.
- **`environment.systemPackages` side (measured 216 derivations)**: no attrPath is
  recorded anywhere — only `pname`/`version`/`drvPath` are known at eval time. Two
  changes made bulk direct-eval practical instead of one `nix eval` per package:
  1. **attrPath identification by drvPath, not name.** For each installed
     derivation, try `<base>.<scope>.<pname>.drvPath` across a fixed set of
     candidate scopes (top level, `kdePackages`, `libsForQt5`, `plasma5Packages`,
     `python3Packages`, `nodePackages`) and bases (`pkgs`, `pkgs.unstable`), and
     accept the first exact `drvPath` match. Measured: only 92 of 216 packages
     resolve at the top level; the rest are mostly `kdePackages.*` KDE Plasma
     components and glibc's multi-output derivations. Every candidate lookup is
     wrapped in `builtins.tryEval` because removed nixpkgs aliases (e.g.
     `libsForQt5.kio-admin`) still exist as attributes but `throw` when
     dereferenced. A package with no drvPath match anywhere is reported as
     unresolved (`attr_resolved=0`) rather than guessed from its name.
  2. **One bulk `nix eval` per channel, not one per package.** All attrPaths
     resolved for a channel are looked up in a single
     `nix eval --json <channel>#legacyPackages.x86_64-linux --apply <fn>` call.
     Measured ~0.6s for all 216 attributes with a warm evaluation cache — the cost
     that made per-package eval impractical was process-startup and
     evaluation-cache-rebuild overhead repeated 216 times, not the evaluation
     itself.

## Follow-up: orphaned textfiles

Both modules' output filenames changed as part of this switch
(`repology-package-status.prom` → `nixos-package-upstream-status.prom`,
`nix-profile-repology-status.prom` → `nix-profile-upstream-status.prom`). Neither
old file is deleted by anything once its writer is gone — the textfile collector
reads every `*.prom` file present, so a stale file keeps being scraped forever
unless something explicitly removes it. Both modules now carry a
`systemd.tmpfiles.rules` entry (`"r <old-path> - - - -"`) to delete the orphan.
Confirmed on the live host: without this, node_exporter kept serving the dead
`nixos_package_repology_*` series indefinitely.

## Rejected alternative

Waiting for repology.org's registrar suspension to resolve and keeping the
Repology-based approach was rejected — the name-matching and version-provenance
problems above predate the outage and would recur.
