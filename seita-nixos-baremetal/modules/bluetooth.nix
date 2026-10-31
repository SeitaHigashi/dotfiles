{ config, lib, pkgs, ... }:

##############################################################################
# Bluetooth (BlueZ) — enabled to receive BLE advertisements from the Eufy
# Smart Scale P3 (T9150) placed next to the server (adapter: TP-Link UB500,
# RTL8761BU). T9150 broadcasts weight in its advertisement manufacturer
# data, so no pairing/connection is needed to read it (eufylife-ble-client
# / Home Assistant eufylife_ble support this model).
#
# Goal: a weight-logging path into seita-health that does not depend on
# the flaky EufyLife -> Health Connect sync. This module only turns on the
# BlueZ stack; the receiver service is wired up separately. (2026-10-31)
##############################################################################

{
  hardware.bluetooth.enable = true;
}
