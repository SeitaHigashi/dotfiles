{ ... }:

##############################################################################
# The single, only place this host's unfree policy is defined:
# nixpkgs.config.allowUnfree = true (unfree packages are allowed by default).
#
# Until 2026-10-26 this file held an allowUnfreePredicate allowlist, so
# unrelated non-free packages could not slip in unnoticed. That stance was
# retired by Seita's decision after nixpkgs-auto bumped rtk 0.50.0 -> 1.0.1,
# whose license gained BSL 1.1 (unfree in nixpkgs); rtk was not on the
# allowlist, so the nightly nix-auto-update failed evaluation and the
# channel stalled. Details: docs/nixpkgs-channels.md
#
# When you change this file, update docs/nixpkgs-channels.md in the same commit.
##############################################################################

{
  nixpkgs.config.allowUnfree = true;
}
