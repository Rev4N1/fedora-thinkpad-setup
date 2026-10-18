# fedora-thinkpad-setup

My post-install and maintenance scripts for **Fedora 44 Workstation (GNOME)** on a
**ThinkPad T14 Gen 1 AMD** (Ryzen 4000 / Renoir).

## `fedora44-setup.sh`

Sets the laptop up from a fresh install, and keeps it maintained. Every stage
checks what is already done, so the same plain run works for both.

```bash
./fedora44-setup.sh             # set up / maintain
./fedora44-setup.sh --dry-run   # show what it would do, change nothing
./fedora44-setup.sh audio vpn   # run only some stages
./fedora44-setup.sh --help      # stages and options
```

What it covers: dnf tuning, RPM Fusion, full codecs, AMD VA-API/Vulkan
(freeworld), Flathub, Helium, VS Code, Spotifast, Nuvio, Discord, EasyEffects
with the T14 Gen 1 speaker profile, WireGuard tunnel import, GNOME tweaks,
power/firmware/fingerprint, a health check and system cleanup.

WireGuard: put your tunnel `.conf` files in a `wireguard/` folder next to the
script and they are imported into NetworkManager. That folder is git-ignored —
the files contain private keys.

Logs go to `~/.local/state/fedora-setup/logs/`.

## `install-uscreen-fedora.sh`

Optional, standalone: installs [UScreen](https://github.com/majmichu1/UScreen)
to use an Android tablet as a second monitor (builds the evdi kernel module via
DKMS). Re-run it to update.

```bash
./install-uscreen-fedora.sh
```

## Credits

- [wz790/Fedora-Noble-Setup](https://github.com/wz790/Fedora-Noble-Setup) — the
  post-install guide most of the base setup follows.
- [RobertKDavis/Fedora-Setup](https://github.com/RobertKDavis/Fedora-Setup) —
  fork of the above, used as the starting point for these scripts.
- [shuhaowu/linux-thinkpad-speaker-improvements](https://github.com/shuhaowu/linux-thinkpad-speaker-improvements)
  — the T14 Gen 1 impulse response files (Dolby profiles) used for the
  EasyEffects speaker preset; the script downloads them from there.
- [majmichu1/UScreen](https://github.com/majmichu1/UScreen) and
  [DisplayLink/evdi](https://github.com/DisplayLink/evdi) — what the UScreen
  installer sets up, following UScreen's installation docs.
- [RPM Fusion](https://rpmfusion.org/Howto/Multimedia) — codec and freeworld
  driver instructions.

## License

GPL-3.0, the same as the guides this is based on. See [LICENSE](LICENSE).

Not official Fedora documentation — read the scripts before running them.
