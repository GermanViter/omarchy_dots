# Dotfiles

Personal configuration files and environment settings for Linux. 

## Contents
- [Overview](#overview)
- [Screenshots](#screenshots)
- [Managed Applications](#managed-applications)
- [Dependencies](#dependencies)
- [Installation](#installation)
- [Script Options](#script-options)
- [Theme Switcher](#theme-switcher)
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
- **UI/Window Management**: [Kitty](https://sw.kovidgoyal.net/kitty/)
- **CLI Tools**: [Fastfetch](https://github.com/fastfetch-cli/fastfetch), [Bat](https://github.com/sharkdp/bat) 

## Local Overrides

To add private configurations (like work-specific paths or API keys) without committing them to the repository, use local override files:
- **Zsh**: Create `~/.zshrc.local`

These files are ignored by Git.

## Dependencies
The setup script is intended for Omarchy and automatically installs missing packages through `omarchy pkg add`:
- **Git** (for cloning the repository)
- **Zsh** (for shell configurations)
- **Kitty**, **Fastfetch**, and **Starship** (configured applications)
- **GNU Stow** (for setting up the symlinks)

## Installation

To apply these configurations to a new system:

1. **Clone the repository on Omarchy:**
   ```bash
   git clone https://github.com/your-username/dotfiles.git ~/.dotfiles
   ```

2. **Run the setup script:**
   The script uses [GNU Stow](https://www.gnu.org/software/stow/) to manage symlinks. It will automatically detect packages in the repository and link them to your home directory.

### Script Options

- `(no arguments)`: Creates symlinks using `stow`.
- `--dry-run`: Simulates the process without making any changes.
- `--unlink`: Removes the symlinks (unstow).
- `--help`: Displays help information.

## Theme Switcher

The `combined_dots/scripts/switch-theme.sh` script allows you to quickly switch between different color schemes across multiple applications.

### Usage
```bash
~/.dotfiles/combined_dots/scripts/switch-theme.sh [main|moon|dawn|catppuccin|black|gruvbox]
```

### Supported Themes
- **main**: Rosé Pine (Default)
- **moon**: Rosé Pine Moon
- **dawn**: Rosé Pine Dawn
- **catppuccin**: Catppuccin Mocha
- **black**: Black Metal Gorgoroth
- **gruvbox**: Gruvbox Dark

### What it updates:
- **Kitty**: Reloads all active instances with the new theme color scheme.
- **Neovim**: Updates the local theme variant configuration file (`theme_variant.lua`).
- **Starship**: Restores the theme-specific prompt configuration (`starship.toml`).
- *Note: Other applications (such as Tmux, Yazi, Waybar, Wofi, Ghostty, Alacritty) will also be updated automatically if their configurations are added to this repository.*

---

## How it Works

The `combined_dots/scripts/setup_symlinks.sh` script is a wrapper around `stow`:

1. **Modular Packages**: Packages inside `combined_dots/` (e.g., `zsh`, `kitty`, `fastfetch`, and `starship`) are automatically detected and treated as "stow packages".
2. **Mirroring**: Stow mirrors the internal structure of these directories into your `$HOME`.
   - `combined_dots/zsh/.zshrc` becomes `~/.zshrc`
   - `combined_dots/nvim/.config/nvim/` becomes `~/.config/nvim/`
3. **Safety**: Stow will not overwrite existing real files. It only creates symlinks. If a file already exists, it will report a conflict.

## Updating configurations
To update your configurations after pulling new changes from the repository:
1. Pull the latest changes:
   ```bash
   git pull
   ```
2. Re-run the setup script to apply any new symlinks:
   ```bash
   ~/.dotfiles/combined_dots/scripts/setup_symlinks.sh
   ```

## Troubleshooting
- If you can't run the script, ensure it has execute permissions:
  ```bash
  chmod +x ~/.dotfiles/combined_dots/scripts/setup_symlinks.sh
  ```
- If you encounter issues with symlinks, check the backup directory for any files that were moved.
- For any application-specific issues, refer to the respective application's documentation or open an issue in this repository.

## Adding New Configs

To add a new application to this repo:
1. **Create a folder** named after the application (e.g., `fastfetch`). 
   - *Note: Avoid reserved names like `scripts`, `assets`, or `gemini` as the script is configured to ignore them.*
   - *Note: Do not start the folder name with a dot (use `zsh/`, not `.zsh/`).*
2. **Mirror the destination structure** inside that folder:
   - If the config belongs in `~/.config/app/config`, create `app/.config/app/config`.
   - If the config belongs in `~/.apprc`, create `app/.apprc`.
3. **Run the setup script** to apply the changes:
   ```bash
   ./combined_dots/scripts/setup_symlinks.sh
   ```
