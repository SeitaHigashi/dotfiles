# LLM models and state moved to an rpool dataset; bonsai-workspaces brought into the repo

2026-10-03. Context: llama-cpp's models lived in `~/bonsai-workspaces/models` on `dpool/home` (HDD
mirror), and the service's working tree (`~/bonsai-workspaces`) was outside git. The user wanted a
service-grade location.

## Decision

- New dataset `rpool/var/lib/llm-models` (NVMe), mounted at `/var/lib/llm-models`: `recordsize=1M`,
  `compression=off`, `com.sun:auto-snapshot=false`, not replicated. Models are re-downloadable, so
  single-SSD `rpool` redundancy is enough (the user's call: "SSD only").
- Laya's and Jeff's regenerable state (venvs, HF cache, checkpoint) moves to
  `/var/lib/llm-models/{laya,jeff}`, not into the repo: `.dotfiles` sits on the HDD and would put ~9 GiB
  of venvs in snapshots. Venvs are not relocatable (absolute paths), so `laya-setup` / `jeff-setup`
  rebuilt them (cached wheels, tens of seconds); hf and the checkpoint were moved as-is.
- `~/bonsai-workspaces` became `seita-nixos-baremetal/llm/` (flake, scripts, `models.ini`, README;
  no `result*`, no state). It is the `llama-cpp.service` WorkingDirectory and the source of truth for the
  prism rev (`llm/flake.lock`, mirrored in `modules/llama-cpp.nix`).
- The retired `rpool/var/lib/ollama` (80.8 GiB) was destroyed after switching its block out of
  `disko/default.nix` (commented out, restore steps inline).

## Measurements

| | result |
|---|---|
| Copy HDD -> NVMe (rsync, 71,834,621,888 bytes) | ~176-220 MB/s, bound by the HDD mirror's reads |
| bonsai cold request via llama-swap (NVMe) | 15.1 s (reads ~510 MB/s for ~12 s); warm 0.48 s |
| Same-size read from the HDD mirror (`dd`, 6.7 GiB) | 30.6 s, 234 MB/s (not a llama-swap load) |
| jeff / laya cold request after the move | 15.1 s / 12.1 s, both answered correctly |

The ~510 MB/s NVMe read is far below the drive's rating; the limit is probably ZFS/mmap access
pattern, not the disk (unverified). Jeff's 15 s cold start is about twice the 7 s recorded on 2026-10-03
earlier; cause not pinned down (fresh venv, cold caches are suspects).

## Procedure that worked (reuse for any new dataset)

`zfs create` by hand with the same options as the disko block, mount it, `rsync -aHAX`, then edit
disko + the module, `nix build`, switch from tmux/console. Adding the disko block before the
dataset exists drops the host into emergency mode (CLAUDE.md, disko section). Removing a dataset
works the other way round: switch the disko block out first, `umount`, then `zfs destroy`.

Details: [llama-cpp.md](../services/llama-cpp.md#where-models-live),
[storage-zfs.md](../storage-zfs.md) §4.
