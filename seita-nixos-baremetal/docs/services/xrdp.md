# xrdp (remote desktop)

Implementation: [`modules/xrdp.nix`](../../modules/xrdp.nix)

## What it is

RDP access to a throwaway Plasma (X11) session on this host, for the
occasional GUI chore that has no CLI (first example: enrolling the
server's Brave into a Brave Sync chain). Added 2026-10-26 at Seita's
request.

## Access

- Tailnet only: `seita-nixos-baremetal.tail5426c0.ts.net:3389` (or the
  host's tailnet IP). The daemon listens on all interfaces, but the
  firewall opens 3389 on `tailscale0` only — never expose it to the LAN
  or the internet; the login is the account password (PAM).
- From Windows: the built-in Remote Desktop Connection (mstsc). Log in
  as `seita`; the session starts Plasma via `startplasma-x11`.

## Notes

- The RDP session is a virtual display (xorgxrdp), separate from the
  projector console session; HDMI output and the BusID pin in
  `modules/desktop.nix` are unaffected.
- Audio forwarding is off (module default; PulseAudio-only, this host
  runs PipeWire, and the use case needs no sound).
- Plasma may show polkit / color-profile authentication prompts inside
  remote sessions. If they get in the way, silence them with a polkit
  rule rather than weakening authentication globally.
