# mpwrap.nvim - Quick Reference Card

## Installation

```lua
-- lazy.nvim
{ "barbera01/MPWrap", config = function() require("mpwrap").setup() end }
```

## Commands

| Command | Action |
|---------|--------|
| `:MpWrapToggle` | Toggle panel |
| `:MpWrapOpen` | Open panel |
| `:MpWrapClose` | Close panel |
| `:MpWrapRepl` | Focus REPL |
| `:MpWrapReplStop` | Stop REPL |
| `:MpWrapFs` | Focus filesystem |
| `:MpWrapSyncBuffer [path]` | Sync buffer |
| `:MpWrapUpload [path]` | Sync buffer (alias) |
| `:MpWrapSyncDir [dir]` | Exact-mirror dir sync to `:` |
| `:MpWrapDownload <src> [dst]` | Download file |
| `:MpWrapVersion` | Show version |
| `:MpWrapDevice` | Pick device |

## Panel Layout

Three stacked windows: **Menu** (top) → **Filesystem** (middle) → **REPL** (bottom).

## Menu Pane

Panel navigation: `<Tab>` next pane, `<S-Tab>` previous pane. In a live REPL,
press `<Esc><Esc>` first; terminal-insert `<Tab>` remains available for
MicroPython completion.

Two sections, highlight + `<CR>` to run, or use the direct key:

| Key | Action |
|-----|--------|
| `1` | Soft reset device |
| `2` | Sync device clock (RTC) |
| `3` | Disk usage (`df`) |
| `4` | Run a snippet (`exec`), prompted |
| `r` | Refresh |
| `u` | Sync current buffer |
| `S` | Sync directory to `:` (exact mirror), browse to pick it |
| `m` | Mkdir |
| `-` | Parent directory |
| `C` | Clear all files (confirm) |
| `x` | Restart device |
| `R` | Start REPL |
| `s` | Stop REPL |
| `q` | Close panel |

## Keybindings (Filesystem Pane)

The Menu Pane keys above also work here. Entry-specific:

| Key | Action |
|-----|--------|
| `<CR>` | Open file under cursor (cache-backed) |
| `a` | Focus the menu pane |
| `D` | Download to local path |
| `M` | Move to local path |
| `dd` | Delete |

## Window Navigation

| Key | Action |
|-----|--------|
| `<C-w>w` | Cycle through windows |
| `<C-w>j` / `<C-w>k` | Move down/up between panel windows |
| `<C-w>h` / `<C-w>l` | Move to/from your main editing window |

## Health Check

```vim
:checkhealth mpwrap
```
Reports Neovim version, whether `mpremote` is on PATH (and its version), visible devices, and config validity.

## Configuration

```lua
require("mpwrap").setup({
  mpremote_cmd = "mpremote",
  device = "auto",
  panel_width = 50,
  panel_position = "right",
  repl_height_ratio = 0.4,
  keymaps = true,
})
```

## Quick Workflow

1. `:MpWrapToggle` - Open panel
2. `j`/`k` - Navigate files
3. `<CR>` - Open file
4. Edit file
5. `u` - Upload
6. `x` - Restart device (any fs action interrupts a running program - `main.py` won't come back up on its own)
7. `:MpWrapRepl` - Watch it boot / test in REPL

Notes:
- Upload includes unsaved buffer edits
- Download prompts before overwrite

## Troubleshooting

**Device not found?**
```vim
:MpWrapDevice
```

**Permission denied?** (Linux)
```bash
sudo usermod -a -G dialout $USER
```

## Links

- Repo: https://github.com/barbera01/MPWrap
- Docs: README.md
- Quick Start: QUICKSTART.md
