# factoryai-linux

Unofficial Linux port of the [Factory](https://factory.ai) desktop app. Factory ships official installers for macOS and Windows only; this project assembles a native Linux install from Factory's first-party sources (official desktop installer + `@factory/cli` + Electron).

[![Linux](https://img.shields.io/badge/platform-Linux-FCC624?logo=linux&logoColor=black)](https://kernel.org)
[![Arch Linux](https://img.shields.io/badge/Arch-Linux-1793D1?logo=archlinux&logoColor=white)](https://archlinux.org)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com)
[![x64](https://img.shields.io/badge/x64-supported-2ea043)](install-factory-linux.sh)
[![arm64](https://img.shields.io/badge/arm64-supported-2ea043)](install-factory-linux.sh)

> **Unofficial.** Not affiliated with or endorsed by Factory AI. Everything is downloaded at install time from Factory's own CDN and npm registry; nothing is redistributed here.

## What gets installed

| Component | Location | Command |
|-----------|----------|---------|
| Desktop app | `~/.local/share/Factory` | `factory` |
| Launcher | `~/.local/bin/factory` | — |
| App menu entry | `~/.local/share/applications/factory.desktop` | — |
| Bundled daemon (desktop only) | `~/.local/share/Factory/runtime/resources/bin/droid` | used internally by the app |

The desktop installer bundles a `droid` daemon for the app UI. For terminal use, install the official CLI separately (see below).

## Requirements

- **bash**, **curl**, **7z** (`p7zip-full`), **tar**
- **Node.js ≥ 20** and **npm** (used to resolve version-matched binaries during install)
- **x86_64** or **aarch64** Linux

Optional (better icons / desktop integration):

- **Python 3** with Pillow (icon resizing)
- **xdg-utils**, **GTK 3** (`gtk-update-icon-cache`)

Ensure `~/.local/bin` is on your `PATH`.

---

## Desktop app

### Arch Linux

Install dependencies:

```bash
sudo pacman -S bash curl p7zip tar nodejs npm
# optional
sudo pacman -S python-pillow gtk3 xdg-utils
```

Download and run the installer:

```bash
git clone https://github.com/keejkrej/factoryai-linux.git
cd factoryai-linux
./install-factory-linux.sh
```

Launch from a terminal or your app menu:

```bash
factory
```

### Ubuntu

Install dependencies:

```bash
sudo apt update
sudo apt install bash curl p7zip-full tar nodejs npm
# optional
sudo apt install python3-pil libgtk-3-0 xdg-utils
```

Ubuntu's default Node.js may be older than 20. If the installer complains, install a current Node release first (e.g. via [NodeSource](https://github.com/nodesource/distributions) or [nvm](https://github.com/nvm-sh/nvm)) and re-run the script.

Download and run the installer:

```bash
git clone https://github.com/keejkrej/factoryai-linux.git
cd factoryai-linux
./install-factory-linux.sh
```

Launch:

```bash
factory
```

### Install options

```bash
# system-wide install (requires sudo)
PREFIX=/opt/Factory sudo -E ./install-factory-linux.sh

# pin a desktop version
FACTORY_VERSION=0.124.0 ./install-factory-linux.sh

# force installer source (default: .exe on x64, .dmg on arm64)
FACTORY_SOURCE=exe ./install-factory-linux.sh
FACTORY_SOURCE=dmg ./install-factory-linux.sh
```

---

## CLI (`droid`)

The official Factory CLI is published on npm as `@factory/cli`. It is separate from the desktop app installer and is the recommended way to use `droid` in a terminal.

### Arch Linux

```bash
sudo pacman -S nodejs npm   # Node.js ≥ 20
npm install -g @factory/cli
droid --help
```

### Ubuntu

```bash
sudo apt install nodejs npm   # ensure Node.js ≥ 20 (see note above)
npm install -g @factory/cli
droid --help
```

To remove the global CLI:

```bash
npm uninstall -g @factory/cli
```

---

## Uninstall

Remove the desktop app (launcher, app menu entry, icons, and app files):

```bash
./uninstall-factory-linux.sh
```

Options:

```bash
# also delete the download cache (~/.cache/factory-linux)
REMOVE_CACHE=1 ./uninstall-factory-linux.sh

# also remove globally installed @factory/cli
REMOVE_GLOBAL_CLI=1 ./uninstall-factory-linux.sh

# if you used a custom prefix
PREFIX=/opt/Factory sudo -E ./uninstall-factory-linux.sh
```

---

## How it works

The install script:

1. Downloads the latest official macOS or Windows desktop installer from Factory
2. Extracts `app.asar` and patches it for Linux (native titlebar, auto-hide menu bar)
3. Fetches the matching Linux `droid` binary from `@factory/cli-linux-<arch>` on npm
4. Downloads the Electron runtime version pinned by the app
5. Assembles everything under `~/.local/share/Factory` and writes a `factory` launcher

No binaries are stored in this repository.

## Troubleshooting

- **`~/.local/bin` not on PATH** — add to your shell rc: `export PATH="$HOME/.local/bin:$PATH"`
- **GPU / sandbox errors** — the launcher passes `--no-sandbox` and software-GL flags by default; override with `FACTORY_GPU_FLAGS="" factory` if your GPU works fine
- **Reinstall** — run `./install-factory-linux.sh` again; it replaces the existing install

## License

Install scripts only. Factory app binaries and assets remain subject to [Factory's terms](https://factory.ai).
