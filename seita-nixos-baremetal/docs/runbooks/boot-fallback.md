# Boot fallback: one-shot trial boots

Adopted 2026-10-27 (user decision). Use this procedure for any change
that can plausibly break booting: NixOS release upgrades, kernel or
ZFS changes, initrd / bootloader changes. The idea: the new generation
is booted exactly once, on top of a known-good default. If it fails,
the next boot falls back to the known-good generation with no menu
interaction.

## Pieces already in place

- systemd-boot with `configurationLimit = 20` (configuration.nix), so
  the known-good generation stays in the menu.
- Hardware watchdog (configuration.nix: `systemd.watchdog`,
  runtimeTime 30s, rebootTime 3min, SP5100 TCO). A hard hang resets
  the machine unattended, which is what makes the fallback automatic
  for hangs.
- `boot.zfs.forceImportRoot = true` (modules/zfs.nix), so a
  watchdog-forced reset does not block pool import on the next boot.
- A trial never touches the pools: **never `zpool upgrade`** as part
  of a change being trialled. Without a pool upgrade, the old
  generation can always import the pools, so rollback stays possible.

## Procedure

1. Install the new generation as a boot entry (do not switch):

       sudo nixos-rebuild boot --flake /etc/nixos

2. List the entries and note both ids (titles carry generation
   numbers):

       sudo bootctl list

   - new entry: the generation just installed
   - known-good entry: the generation running before this change

3. Make the known-good generation the default, and the new one a
   one-shot:

       sudo bootctl set-default <known-good-entry>
       sudo bootctl set-oneshot <new-entry>

4. Reboot. Outcomes:

   - **Boots fine** → promote the new generation to default right
     away, so a later unrelated power cycle does not fall back:

         sudo bootctl set-default <new-entry>

     (The next `nixos-rebuild` also regenerates loader.conf with the
     newest generation as default, but do not rely on that happening
     before an unrelated reboot.)
   - **Fails early / emergency shell** → power-cycle. The one-shot is
     consumed, so the known-good default boots. Fix forward from the
     old system; do not re-trial until the cause is understood.
   - **Hangs** → the watchdog resets the machine (~30s), same result
     as a power-cycle. Exception: if the machine sits in an emergency
     shell with systemd still alive, the watchdog keeps being fed and
     nothing resets it; a human power-cycle is the recovery (the
     fallback itself is still automatic after the cycle).

## Notes

- `bootctl set-default` / `set-oneshot` write loader.conf / EFI
  variables outside Nix's management. That is deliberate and local to
  the trial; a rebuild regenerates loader.conf as usual.
- systemd's boot counting (`systemd-bless-boot`) would automate the
  promotion step too, but it assumes entry filenames NixOS does not
  generate, so it does not compose with NixOS generations. The
  one-shot procedure above is the practical equivalent here.
