# joe Linux ARM on dynamod

joe Linux's upgrade model rests on four behaviours that systemd provided
through units shipped with dave (joe-linux's `system/`). On joe Linux ARM
dynamod provides them. This is how each maps, and what dynamod needs for it.

## The four behaviours

| joe Linux (systemd) | What it guarantees | joe Linux ARM (dynamod) |
|---------------------|--------------------|-------------------------|
| `dave-seal.service`, before `sysinit.target`, once | An image assembled without privileges is sealed on its first boot, before anything privileged runs from it | An `early-boot` oneshot ordered before every other service, skipped once `/usr/lib/dave/sealed` exists |
| `dave-finalize.service`: `ExecStop=dave finalize`, while local file systems are still mounted | A prepared upgrade is applied to a snapshot at shutdown | A service that stays up after its start command exits, whose `stop-exec` is `dave finalize`, stopped after every service that depends on the file systems and before dynamod-init unmounts them |
| `dave-boot-check.service` before `boot-complete.target`; `systemd-bless-boot` marks the entry good; `FailureAction=reboot` | A new deployment counts as good only after it has booted and passed its check; otherwise systemd-boot's counter runs out and the previous one returns | A oneshot run once every other service is up; on success dave itself removes the boot counter from the entry's file name (as systemd-bless-boot would), on failure the machine reboots |
| `boot-complete.target` `JobTimeoutSec=10min`, `reboot-force` | A deployment that never finishes booting is abandoned | A watchdog started first: if the boot check has not passed after 10 minutes, it forces a reboot |

systemd-boot (an EFI program) and its boot counting are unchanged, so dave's
`boot.zig` keeps its contract with the loader. What changes in dave:
`boot-check` blesses the entry itself, and it reboots with `reboot` instead of
`systemctl reboot`.

## What dynamod needs

1. **Vendor and administrator directories.** Packages install service and
   supervisor definitions under `/usr/lib/dynamod/{services,supervisors}`;
   `/etc/dynamod/...` holds the administrator's, and a file there replaces
   the packaged one of the same name. On joe `/etc` belongs to each
   deployment and `/usr` is sealed, so packages may not write `/etc`.
2. **Enabled and disabled services.** joe starts optional servers only
   when the administrator asks (`enable --now`). A service is started at
   boot if its definition says so (core services) or if it has been enabled
   (`/etc/dynamod/enabled/NAME`, created by `dynamodctl enable NAME`).
3. **Oneshots that stay up** (`remain-after-exit`), so that a stop command
   runs at shutdown: dave-finalize.
4. **"After everything"** ordering, for the boot check: a service that starts
   once every other service enabled at boot is ready or has failed.
5. **A failure action**: reboot the machine if this service fails (the boot
   check), and a start timeout with the same action (the watchdog), or the
   watchdog as an ordinary service.
6. **The usual commands**: `reboot`, `poweroff`, `halt` and `shutdown`
   (with `-r`, `-h`, `now`), and a `systemctl` that understands `start`,
   `stop`, `restart`, `status`, `enable [--now]`, `disable [--now]`,
   `is-active`, `is-enabled`, `list-units`, `reboot`, `poweroff` in terms of
   dynamod's services. This is the command-line half of dynamod's systemd
   compatibility.
7. **`tmpfiles.d` and `sysusers.d`.** joe's packages create what they need
   under `/var` and their system users declaratively (packages may not ship
   anything under `/var`, which every deployment shares, and system users
   must have fixed ids). Without systemd, something must read these files at
   boot and when packages change: dynamod-tmpfiles and dynamod-sysusers,
   compatible with the systemd formats, also run by dave as triggers.
8. **Building on bionic**: the Rust crates are built for
   `aarch64-linux-android` against joe's bionic; the sd_notify shim is a
   cdylib, which bionic (unlike static musl) supports.

dynamod-init (the Zig PID 1) needs nothing of this: it is ported to Zig
0.17.1 and aarch64 on the `aarch64-bionic` branch of
[theJoeLinuxFoundation/dynamod](https://github.com/theJoeLinuxFoundation/dynamod).
joe boots without an initramfs, so it starts in its "real root" phase.

## Devices, logs, network

- **udev**: eudev, for `/dev/disk/by-*` links and the rules packages ship;
  dynamod already has udev and udev-coldplug services.
- **logs**: dynamod-logd, with syslog datagrams on `/dev/log` (bionic's
  syslog(3) is patched to send them there).
- **network**: dhcpcd on wired interfaces by default, replacing
  systemd-networkd's `80-joe-wired.network`.
- **root growth**: on first boot the root partition and file system grow to
  fill the disk (systemd-repart and systemd-growfs on joe Linux), done by a
  oneshot with sfdisk and `btrfs filesystem resize`.
