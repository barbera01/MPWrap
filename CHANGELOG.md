# Changelog

All notable changes to mpwrap.nvim will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Normal-mode `<Tab>` / `<S-Tab>` navigation cycles through all three panel panes while preserving terminal-insert Tab for MicroPython REPL completion
- `:MpWrapSyncBuffer [remote_path]` command (with `:MpWrapUpload` compatibility alias)
- `:MpWrapSyncDir [local_dir]` exact-mirror directory sync to remote root (`:`), with plan + destructive-delete confirmation
- Panel action/key for directory sync (`keys.sync_dir`, default `S`) - opens a breadcrumb directory browser (`vim.ui.select`, with a "[Type a path manually]" escape hatch to `vim.ui.input`) to pick the local sync source rather than assuming Neovim's cwd, since the device code doesn't always live at the cwd root. Remembers the last directory picked per session as the next browse's starting point.
- Configured sync ignores via `sync_ignore` and `sync_ignore_extra`
- Filesystem sync APIs: `plan_directory_sync` and `apply_directory_sync`
- Help doc: `doc/mpwrap.txt` with tags for commands/configuration and panel behavior
- REPL pane now shows `boot.py`/`main.py` output on start, by sending Ctrl-D once mpremote connects (`reset_on_repl_start` config, default on)
- `C` - Clear all files in the current remote directory (recursive; mpremote's `fs rm`/`fs rmdir` have no recursive flag)
- `x` - Restart the device, so a program that was running (e.g. a web server) restarts after any filesystem action interrupted it
- Three-pane panel layout: a permanently visible action menu (top, highlight + `<CR>` to run), filesystem browser (middle), REPL (bottom)
- `mpremote` menu section (above Actions): soft reset, sync device RTC, disk usage (`df`), and a one-line exec snippet prompt (auto-stopped after 15s if it doesn't return, since a blocking snippet would otherwise wedge every other filesystem action with no way to cancel)
- Winbar titles: overall `MicroPython Panel — <device>` on the menu pane, `REPL — running/stopped` on the REPL pane (green/red via new `MpWrapStatusRunning`/`MpWrapStatusStopped` highlight groups, linked to `DiagnosticOk`/`DiagnosticError` so they follow the active colorscheme)
- REPL pane text wraps instead of running off-screen - `'wrap'` set explicitly on the window (both the placeholder buffer and, separately, right after `termopen` creates the live terminal buffer, since termopen resets it to `nowrap` once as part of entering the buffer)
- Menu/fs pane divider lines resize dynamically with the panel, via `WinResized`/`VimResized` autocmds re-rendering both panes (confirmed working for `VimResized` - resizing the whole terminal; `WinResized` - a single split being dragged - is implemented per Neovim's documented pattern but unverifiable in headless testing, since that event depends on a real attached UI's redraw cycle)
- `:checkhealth mpwrap` - Neovim version, mpremote presence/version, device visibility, config validity
- `config.validate()` - unknown option/`keys.*` names and wrong types now report a clear error at `setup()` time instead of misbehaving later
- Real test suite (`tests/*_spec.lua`, `scripts/test.sh` / `make test`) that exits non-zero on failure, including headless coverage of `panel.lua`'s window layout and action dispatch (previously untested)
- `.luacheckrc`, `stylua.toml`, `Makefile` (`test`/`lint`/`format`/`check`), `.github/workflows/ci.yml`

### Fixed
- Setup hardening: invalid config now throws clear Lua error and is never merged; repeated setup is idempotent and command creation is safe
- Device policy/runtime selection split: `auto`/`pick` behavior separated from selected runtime port
- Neovim compatibility: `WinResized` autocmd is feature-detected, with `VimResized` fallback for older versions
- Files opened from panel use collision-resistant cache paths (hashed by remote path), not CWD
- Download safety: default local download refuses overwrite unless explicitly forced; interactive flows now prompt
- Upload safety: upload of current buffer uses in-memory snapshot (includes unsaved edits) and cleans temp files
- Shared serial lock moved to jobs layer with tokenized lease ownership; stale callbacks cannot release newer owners
- REPL lifecycle: acquires/release shared lease, handles termopen failure cleanup, stale on_exit race, natural-exit callback hooks, and placeholder updates
- Panel lifecycle: manual close/wipe of any panel window/buffer reconciles and closes panel cleanly
- Panel async safety: open-generation token ignores stale callbacks after close/reopen
- Filesystem parser keeps legitimate file names beginning with `ls`
- Replace deprecated `nvim_buf_set_option` with `vim.bo` for Neovim 0.10+ compatibility
- Warn users to stop the embedded REPL before filesystem commands to avoid exclusive serial-port access failures
- `mpremote --version` (and `:MpWrapVersion`) no longer routes through the configured device, so checking the version doesn't try to open the serial port
- Overlapping mpremote invocations (e.g. firing a second panel action before the first finishes) are now rejected with a clear warning instead of silently contending for the serial port
- `repl.stop()` could close the REPL window itself instead of just clearing it, in a sparse session with no other buffers open (force-deleting a still-displayed buffer with nothing to fall back to); it now swaps the window to a fresh buffer before deleting the old one

### Changed
- Renamed the plugin from `mpremote.nvim` to **`mpwrap.nvim`** to make clear it is an independent wrapper, not part of or affiliated with the official `mpremote` tool. Everything follows the new name: `require("mpwrap")`, `:MpWrap*` commands, `MpWrap*` highlight groups, `mpwrap://` buffer names, `mpwrap-*` filetypes, `doc/mpwrap.txt` (`:h mpwrap`), and `:checkhealth mpwrap`. The `mpremote_cmd` config option keeps its name since it refers to the CLI binary being invoked.
- Improve filesystem panel styling and highlight the selected file row
- Add a panel action selector for selected file/directory operations
- Prompt for a MicroPython device on panel open and use that port for filesystem and REPL commands
- Do not auto-start REPL by default; users start it explicitly with `R`/`:MpWrapRepl` so filesystem refresh works reliably first

### Removed
- `BUGFIX_SUMMARY.md`, `PROJECT_COMPLETE.md`, `SUMMARY.md` - one-time historical snapshots, superseded by this changelog
- `DEBUG_PANEL.md` - troubleshooting notes for a bug specific to the old two-pane layout
- `DEMO_GIF_SCRIPT.md`, `DEMO_SCRIPT.md`, `DEMO_STORYBOARD.md` - recording scripts tied to the old UI
- `UPDATE_TROUBLESHOOTING.md`, `force-update-nvim.sh`, `quick-update.sh` - described force-updating a git-clone-based lazy.nvim install; doesn't apply to the actual `dev = true` local-directory setup, which needs no update step at all
- `test.py` - stray unrelated file, not part of the real test suite (`tests/*_spec.lua`)

## [0.1.0] - 2026-01-17

### Added - Initial MVP Release

#### Core Features
- Toggleable side panel with split layout (filesystem + REPL)
- Remote filesystem browser with flat file listing
- Live MicroPython REPL in terminal buffer
- Async command execution (non-blocking)
- Device auto-detection and manual selection

#### Filesystem Operations
- `list` - List files on device
- `upload` - Upload local file to device
- `download` - Download file from device
- `delete` - Delete file on device (with confirmation)
- `mkdir` - Create directory on device
- `open_remote_file` - Download and open in buffer

#### User Commands
- `:MpWrapToggle` - Toggle panel visibility
- `:MpWrapOpen` - Open panel
- `:MpWrapClose` - Close panel
- `:MpWrapRepl` - Focus REPL pane
- `:MpWrapFs` - Focus filesystem pane
- `:MpWrapUpload [path]` - Upload current buffer
- `:MpWrapDownload <remote> [local]` - Download file
- `:MpWrapVersion` - Show mpremote version

#### Keybindings (Filesystem Pane)
- `<CR>` - Open file under cursor
- `r` - Refresh file listing
- `u` - Upload current buffer
- `D` - Download file under cursor to a local path
- `M` - Move file under cursor to a local path, deleting remote after download
- `dd` - Delete file under cursor
- `m` - Create directory
- `q` - Close panel

#### Configuration
- `mpremote_cmd` - Command to invoke mpremote
- `device` - Device selection (auto or explicit port)
- `panel_width` - Panel width in columns
- `panel_position` - Panel position (left/right)
- `repl_height_ratio` - REPL height as ratio
- `keymaps` - Enable/disable default keybindings
- `keys` - Customize keybinding mappings

#### Modules
- `config.lua` - Configuration management
- `jobs.lua` - Async job execution
- `fs.lua` - Filesystem operations
- `repl.lua` - REPL terminal management
- `panel.lua` - UI layout management
- `init.lua` - Main entry point

#### Documentation
- README.md - User documentation
- ARCHITECTURE.md - Technical documentation
- KEYBINDINGS.md - Keybinding reference
- QUICKSTART.md - Quick start guide
- SUMMARY.md - Implementation summary
- LICENSE - MIT license

### Technical Details
- Requires Neovim >= 0.8.0
- Uses `vim.fn.jobstart()` for async execution
- Uses `vim.fn.termopen()` for REPL
- No external Lua dependencies
- Wraps official `mpremote` CLI tool

## [Future Releases]

### Planned Features (Not in MVP)
- Tree-style directory navigation
- File watching and auto-sync
- Soft/hard reset commands
- Multiple device support (tabs)
- Integration with nvim-dap for debugging
- Syntax highlighting for remote files
- Custom file upload/download mappings
- Configuration profiles for different devices

---

## Version History

- **0.1.0** - Initial MVP release (2026-01-17)
  - Full filesystem browser
  - Interactive REPL
  - Async operations
  - Configurable UI

[Unreleased]: https://github.com/barbera01/MPWrap/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/barbera01/MPWrap/releases/tag/v0.1.0
