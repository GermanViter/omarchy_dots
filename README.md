# Dotfiles

Personal configuration files and environment settings for Linux. 

## Contents
- [Overview](#overview)
- [Screenshots](#screenshots)
- [Managed Applications](#managed-applications)
- [Dependencies](#dependencies)
- [Installation](#installation)
- [Script Options](#script-options)
- [How it Works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Adding New Configs](#adding-new-configs)

## Overview

This repository uses a modular structure where each directory represents an application or tool. A central setup script manages the creation of symbolic links from the repository to your home directory and `~/.config` folder on [Omarchy](https://omarchy.org/).

## Screenshots

<ul align="center">
  <li><h3>Fastfetch</h3><img src="assets/pictures/fastfetch.png" width="400" /></li>
  <li><h3>NeoVim</h3><img src="assets/pictures/nvim.png" width="400" /></li>
</ul>

> [!TIP]
> Checkout my wallpapers on [GermanViter/wallpapers](https://github.com/GermanViter/wallpapers).

## Managed Applications

- **Terminal/Shell**: [Zsh](https://www.zsh.org/)
- **Editors**: [Neovim](https://neovim.io/) (LazyVim)
- **Prompt**: [Starship](https://starship.rs/)
- **UI/Window Management**: [Kitty](https://sw.kovidgoyal.net/kitty/), Hyprland keybindings
- **CLI Tools**: [Fastfetch](https://github.com/fastfetch-cli/fastfetch), [Bat](https://github.com/sharkdp/bat) 

## Local Overrides

To add private configurations (like work-specific paths or API keys) without committing them to the repository, use local override files:
- **Zsh**: Create `~/.zshrc.local`

These files are ignored by Git.

## Dependencies
The unified install script is designed specifically for Omarchy and automatically manages dependencies through `omarchy pkg add`:
- **Core Dependencies**: `stow`, `fzf`, `eza`, `bat`, `zoxide`, `starship`, `fastfetch`
- **Extended Tools** (with `--all`): `neovim`, `kitty`, `tmux`, `git`, `zsh`

## Installation

To apply these configurations to a new system:

1. **Clone the repository on Omarchy:**
   ```bash
   git clone https://github.com/GermanViter/omarchy_dots.git ~/.dotfiles
   cd ~/.dotfiles
   ```

2. **Run the installer:**
   The unified `scripts/install.sh` script installs core dependencies via `omarchy pkg add` and creates symlinks using [GNU Stow](https://www.gnu.org/software/stow/):
   ```bash
   ./scripts/install.sh
   ```

### Script Options

- `(no arguments)`: Installs core dependencies and creates symlinks.
- `-n, --dry-run`: Simulates the process without making any changes.
- `-d, --deps-only`: Installs dependencies only (skips symlinking).
- `-s, --symlinks-only`: Creates symlinks only (skips dependency installation).
- `-u, --unlink`: Removes the symlinks (unstow).
- `-a, --adopt`: Adopts existing target files into the repository during stowing.
- `--all`: Installs full suite of tools (including Neovim, Kitty, Tmux, Git, Zsh).
- `-c, --check`: Inspects status of dependencies and available stow packages.
- `-h, --help`: Displays help information.

## How it Works

The `scripts/install.sh` script is a wrapper around `stow` and `omarchy pkg`:

1. **Modular Packages**: Package directories (e.g., `zsh`, `kitty`, `fastfetch`, `starship`, and `hypr`) are automatically detected and treated as "stow packages".
2. **Mirroring**: Stow mirrors the internal structure of these directories into your `$HOME`.
   - `zsh/.zshrc` becomes `~/.zshrc`
   - `kitty/.config/kitty/` becomes `~/.config/kitty/`
3. **Safety**: Stow will not overwrite existing real files by default. It only creates symlinks. If a file already exists, it will report a conflict unless `--adopt` is provided.

## Updating configurations
To update your configurations after pulling new changes from the repository:
1. Pull the latest changes:
   ```bash
   git pull
   ```
2. Re-run the install script to apply any new symlinks:
   ```bash
   ~/.dotfiles/scripts/install.sh
   ```

## Troubleshooting
- If you can't run the script, ensure it has execute permissions:
  ```bash
  chmod +x ~/.dotfiles/scripts/install.sh
  ```
- If you encounter conflicts with existing configuration files, use `--adopt` to import them into the repository:
  ```bash
  ./scripts/install.sh --adopt
  ```
- For any application-specific issues, refer to the respective application's documentation or open an issue in this repository.

## Adding New Configs

To add a new application to this repo:
1. **Create a folder** named after the application (e.g., `fastfetch`). 
   - *Note: Avoid reserved names like `scripts`, `assets`, or `gemini` as the script is configured to ignore them.*
   - *Note: Do not start the folder name with a dot (use `zsh/`, not `.zsh/`).*
2. **Mirror the destination structure** inside that folder:
   - If the config belongs in `~/.config/app/config`, create `app/.config/app/config`.
   - If the config belongs in `~/.apprc`, create `app/.apprc`.
3. **Run the install script** to apply the changes:
   ```bash
   ./scripts/install.sh
   ```
