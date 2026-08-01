# scripts/install.sh が scripts/disks.env から自動生成しました。
# 生成日時: 2026-07-30T12:48:49+00:00
{
  hostName = "seita-nixos-baremetal";
  hostId = "8883f53a";

  ssd  = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S7HDNJ0Y914245A";
  hdd1 = "/dev/disk/by-id/ata-ST4000DM004-2U9104_WW638RJX";
  hdd2 = "/dev/disk/by-id/ata-ST4000DM004-2U9104_WW63DE1H";

  efiSize   = "1G";
  swapSize  = "16G";
  slogSize  = "8G";
  useSlog = false;
  ashift = "12";

  nixPool = "rpool";
  arcMaxBytes = 17179869184;

  userName = "seita";
  userDescription = "seita";
  userSshKeys = [
  ];
  userHashedPassword = null;
  rootHashedPassword = null;
  allowPasswordAuth = true;

  staticAddress = "192.168.11.254/24";
  gateway = "192.168.11.1";
  nameservers = [
    "192.168.11.1"
  ];
  networkInterface = "en*";
}
