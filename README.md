# fedora-thinkpad-setup

One script that **sets up, updates and maintains** Fedora GNOME — written on a
**ThinkPad T14 Gen 1 AMD** (Ryzen 4000 / Renoir), but every hardware-specific
step is detected first and skipped elsewhere, so it also runs on a plain
Fedora Workstation or GNOME spin.

On a fresh install, open a terminal and paste:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Rev4N1/fedora-thinkpad-setup/main/fedora-setup.sh)
```

It clones this repo to `~/fedora-thinkpad-setup` (installing `git` if needed)
and runs from there. After that, the one command for everything is:

```bash
fedora-setup
```

That is the whole workflow. The same command on a fresh install sets the
machine up; later it updates everything, puts back any setting that drifted,
checks the machine's health and cleans up. It also updates *itself* from git
before it starts. Run it whenever you like — monthly is plenty; GNOME Software
keeps installing security updates in between.

## What a run does

| Stage | What it does |
| --- | --- |
| `config` | dnf tuning, optional hostname, installs the `fedora-setup` command |
| `update` | system upgrade, fwupd metadata refresh |
| `rpmfusion` | RPM Fusion free/nonfree, AppStream data, OpenH264 repo |
| `flatpak` | Flathub with the full catalogue (clears the stock filter) |
| `amd` | AMD VA-API + Vulkan freeworld drivers (skipped if not AMD) |
| `media` | full ffmpeg, `@multimedia`, GStreamer codecs, OpenH264 |
| `apps` | VS Code, Helium, Spotifast, Nuvio, Discord, archive tools |
| `audio` | EasyEffects + T14 Gen 1 Dolby speaker profile, service, autoload |
| `vpn` | imports `wireguard/*.conf` into NetworkManager |
| `gnome` | touchpad, Night Light, keyboard, battery %, extensions, Ptyxis |
| `laptop` | tuned, TRIM, faster boot, firmware, fingerprint, ThinkPad extras |
| `sweep` | final dnf/Flatpak/firmware pass |
| `health` | read-only health report (services, kernel, battery, disk, scrub) |
| `cleanup` | autoremove, journal, Flatpak runtimes, package cache |

Optional, not part of a plain run:

```bash
fedora-setup release   # upgrade to the next Fedora release (e.g. 44 -> 45)
fedora-setup session   # re-apply the desktop-only steps (runs itself at login when needed)
```

`release` brings the current release up to date, downloads the next one with
`dnf system-upgrade`, and asks before rebooting into the offline upgrade. If
the next release is not out yet, it changes nothing. Run `fedora-setup` once
more after the upgrade.

## Every day use

```bash
fedora-setup                # set up, or maintain
fedora-setup --dry-run      # print every command, change nothing
fedora-setup --yes          # no confirmation prompt
fedora-setup --quiet        # warnings and errors only
fedora-setup health         # just the health report
fedora-setup amd media      # only those stages
fedora-setup --skip vpn     # everything except vpn
fedora-setup --help
```

`config` links `~/.local/bin/fedora-setup` to the script in your checkout, so
the command works from any directory and still finds your `wireguard/`
folder. Each run first does
`git pull --ff-only` on the checkout; disable that with `--no-self-update`.
(`./fedora-setup.sh` inside the checkout is the same thing.)

Every real run is logged to `~/.local/state/fedora-setup/logs/` (last 20 kept),
and a lock prevents two runs overlapping. Runs need your sudo password, so
there is no cron job: just run it yourself now and then.

## Settings

There is no config file: the few settings live at the top of
`fedora-setup.sh`, so the script is the only file you touch.

| Setting | Default | Meaning |
| --- | --- | --- |
| `CFG_HOSTNAME` | empty | leave the hostname alone, or set one |
| `CFG_BROWSER` | `helium` | `helium` or `none` |
| `CFG_TOUCHPAD_SPEED` | `0.45` | `-1.0` .. `1.0` |
| `CFG_AUDIO` | `auto` | `auto` (T14 Gen 1 only), `off`, `force` |
| `CFG_EXTRA_PACKAGES` | empty | extra dnf packages, space separated |
| `REBOOT_PROMPT` | `1` | ask before rebooting at the end |

Edit them in this repo and push: every machine picks the change up on its
next run through the self-update. Local edits on the laptop itself make
`git pull` refuse, and the script then warns and runs the copy it has.

## WireGuard

Drop your tunnel files in `wireguard/` next to the script and they are imported
into NetworkManager, so they appear in the GNOME network menu. The folder and
`*.conf` are git-ignored because the files contain private keys. The script
warns if a tunnel file is readable by other users.

## What is applied automatically

- **EasyEffects** runs as a user service. The T14 Gen 1 Dolby impulse responses
  are downloaded once, a `ThinkPad T14 Speakers` preset (convolver + limiter)
  is written, and autoload profiles pick it for the internal speakers and a
  flat preset for headphones/HDMI. No GUI steps.
- **GNOME extensions** (Dash to Dock, Blur my Shell, Caffeine) are installed
  from Fedora and added to `enabled-extensions`.
- **Desktop-only work** (GNOME keys, extension activation, starting the audio
  service) is queued in `~/.config/autostart` when the script runs without a
  session — e.g. over SSH or from a TTY — and applied once at your next login.

## What cannot be automated

Three things need a human, a finger, or the firmware setup screen. The script
tells you when they apply and never pretends otherwise:

1. **Fingerprint enrollment** — `fprintd-enroll` needs your finger on the
   reader. The PAM feature (`authselect ... with-fingerprint`) is enabled for
   you, so the first finger you enroll works for login and sudo immediately.
2. **Secure Boot / DKMS** (only for the separate UScreen installer's `evdi` module) —
   enrolling the DKMS signing key needs a one-time reboot and password.
3. **BIOS sleep state** — `BIOS > Config > Power > Sleep State: Linux` enables
   deep S3 suspend on the T14 Gen 1. Firmware settings are not writable from
   Linux; the health check warns if you are on `s2idle`.

## Requirements

- Fedora **41 or newer** (dnf5), Workstation or another GNOME spin. Built and
  tested on Fedora 44 / GNOME 50. Atomic editions (Silverblue) are refused.
- Run as your normal user, **not** with `sudo`. The script asks for sudo itself.
- x86_64. GPU, ThinkPad and battery steps are detected and skipped if absent.

## Extras

`install-uscreen-fedora.sh` installs
[UScreen](https://github.com/majmichu1/UScreen) with the `evdi` DKMS module.
It is a separate script, not part of `fedora-setup`: run it yourself when you
want it, and re-run it to update UScreen.

```bash
./install-uscreen-fedora.sh
```

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `another fedora-setup run is already in progress` | wait for it, or remove `~/.local/state/fedora-setup/lock` |
| `Permission denied` on `./fedora-setup.sh` | `chmod +x fedora-setup.sh`, or run `bash fedora-setup.sh` |
| A stage failed | the error names the stage; rerun just it, e.g. `fedora-setup media` |
| Audio profile not active | `systemctl --user status easyeffects`, then `fedora-setup audio` |
| `fedora-setup: command not found` | open a new terminal (`~/.local/bin` joins PATH at login), or use `~/fedora-thinkpad-setup/fedora-setup.sh` |
| Extensions absent after setup | log out and back in (Wayland cannot reload the shell live) |
| Self-update warns | local edits or offline; `git status`, then rerun |
| Want to see exactly what changes | `fedora-setup --dry-run` |

## Credits

- [wz790/Fedora-Noble-Setup](https://github.com/wz790/Fedora-Noble-Setup) — the
  post-install guide most of the base setup follows.
- [RobertKDavis/Fedora-Setup](https://github.com/RobertKDavis/Fedora-Setup) —
  fork of the above, used as the starting point for these scripts.
- [shuhaowu/linux-thinkpad-speaker-improvements](https://github.com/shuhaowu/linux-thinkpad-speaker-improvements)
  — the T14 Gen 1 impulse response files (Dolby profiles).
- [majmichu1/UScreen](https://github.com/majmichu1/UScreen) and
  [DisplayLink/evdi](https://github.com/DisplayLink/evdi) — what the UScreen
  installer sets up.
- [RPM Fusion](https://rpmfusion.org/Howto/Multimedia) — codec and freeworld
  driver instructions.

## License

GPL-3.0, the same as the guides this is based on. See [LICENSE](LICENSE).

Not official Fedora documentation — read the script before you run it.
