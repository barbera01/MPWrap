# Architecture Documentation

## Overview

`mpwrap.nvim` is a Neovim plugin that wraps the `mpremote` CLI tool to provide an integrated MicroPython development experience. The plugin follows Neovim best practices with a modular Lua architecture, async execution, and clean separation of concerns.

## Design Principles

1. **Wrapper, not reimplementation**: We shell out to `mpremote` instead of implementing the serial protocol
2. **Async-first**: All I/O operations are non-blocking
3. **Modular**: Clear separation between UI, business logic, and I/O
4. **Keyboard-first**: Optimized for keyboard-driven workflows
5. **Minimal dependencies**: Only Neovim built-in APIs

## Module Architecture

### Module Dependency Graph

```
init.lua
├── config.lua (configuration)
├── health.lua (:checkhealth provider)
│   ├── jobs.lua
│   └── config.lua
├── panel.lua (UI: menu + filesystem + REPL windows)
│   ├── devices.lua (device picker)
│   │   └── jobs.lua
│   ├── fs.lua (filesystem ops)
│   │   └── jobs.lua (async execution)
│   │       └── config.lua
│   └── repl.lua (terminal)
│       └── config.lua
├── devices.lua
└── jobs.lua
```

### Module Responsibilities

#### `config.lua`
**Purpose**: Configuration management

**Responsibilities**:
- Store user configuration
- Provide defaults
- Build mpremote command arrays with device selection
- Validate configuration

**Public API**:
- `setup(opts)` - Merge user config with defaults, runs `validate()` first. Invalid config throws a clear Lua error and is not merged
- `get()` - Get current configuration
- `get_mpremote_cmd(args)` - Build command array for execution
- `validate(opts)` - Check a (possibly partial) options table against the known option/`keys.*` names and their types; returns `(valid, errors)`. Only checks keys actually present, so it works for both raw `setup()` opts and a fully-merged config - `health.lua` calls it on the live config so `:checkhealth` and `setup()` agree

**State**: Global configuration object

---

#### `jobs.lua`
**Purpose**: Async command execution

**Responsibilities**:
- Execute mpremote commands asynchronously
- Handle stdout/stderr streams
- Provide callbacks for command completion
- Check mpremote availability

**Public API**:
- `execute(args, callback, on_stderr)` - Run async command, args go through `config.get_mpremote_cmd()` (adds `connect <device>` if one is configured), and acquires serial lease
- `execute_raw(args, callback, on_stderr, opts)` - Same, but bypasses device-prefixing - for commands that must never touch the configured device path, like `connect list` or `--version`
- `execute_sync(args, timeout)` - Run blocking command (use sparingly)
- `execute_sync_raw(args, timeout)` - Blocking raw command, used by health checks
- `is_busy()` - True while any `execute`/`execute_raw` job is in flight. mpremote holds the serial port exclusively, so two overlapping invocations (e.g. firing a second panel action before the first's callback chain finishes) would silently corrupt or half-complete one of them; callers check this before starting a new one (see `panel.lua`'s `can_run_filesystem_action()`)
- `check_mpremote()` - Verify mpremote is in PATH
- `get_version(callback)` - Get mpremote version. Uses `execute_raw`, not `execute` - going through the configured device would prepend `connect <device>`, making a plain version check try to open the serial port for no reason

**Key Design**:
- Uses `vim.fn.jobstart()` for async execution
- Buffers stdout/stderr until completion
- Schedules callbacks with `vim.schedule()` for safe API calls
- Returns job_id for potential cancellation
- Tracks an internal in-flight job counter (incremented/decremented around every `jobstart`), exposed via `is_busy()`
- Tokenized serial lease API (`acquire_device_lease` / `release_device_lease`) prevents stale callbacks from releasing newer owners

---

#### `devices.lua`
**Purpose**: Serial device discovery and selection

**Responsibilities**:
- Parse `mpremote connect list` output
- Prompt the user to pick a device (`vim.ui.select`)

**Public API**:
- `list(callback)` - List available devices
- `pick(callback)` - Prompt and set runtime selected device port
- `ensure_selected(callback, opts)` - enforce policy (`auto`/`pick`/explicit)

---

#### `health.lua`
**Purpose**: `:checkhealth mpwrap` provider

**Responsibilities**:
- Report Neovim version compatibility
- Report whether `mpremote` is on PATH and its version
- Best-effort report of visible devices (`mpremote connect list`)
- Report whether the current config passes `config.validate()`

**Key Design**:
- Uses `vim.health` (`.start/.ok/.warn/.error/.info`), falling back to the pre-0.10 `report_*` names since the plugin supports back to Neovim 0.8.0
- All mpremote invocations here are synchronous and bypass `config.get_mpremote_cmd()`'s device-prefixing (a raw `vim.system`/`vim.fn.system` call), for the same reason `jobs.get_version` uses `execute_raw` - a health check must never try to open the configured device's serial port just to check if the CLI itself is reachable

---

#### `fs.lua`
**Purpose**: Filesystem operations on device

**Responsibilities**:
- Wrap mpremote fs subcommands (ls, cp, rm, mkdir)
- Parse mpremote output into structured data
- Provide high-level operations (upload, download, open)
- Manage temporary file cache

**Public API**:
- `list(path, callback)` - List remote files
- `upload(local_path, remote_path, callback)` - Upload file
- `download(remote_path, local_path, callback[, opts])` - Download file (refuses overwrite by default; `opts.force=true` to allow)
- `plan_directory_sync(local_dir, remote_root, opts, callback)` - Build exact-mirror plan only (no deletions during planning)
- `apply_directory_sync(plan, callback, on_progress)` - Apply one-shot plan sequentially
- `delete(remote_path, callback)` - Delete remote file
- `mkdir(remote_path, callback)` - Create directory
- `clear_directory(path, callback)` - Recursively delete everything under `path`, leaving `path` itself intact. mpremote's `fs rm`/`fs rmdir` have no recursive flag, so this lists the directory, deletes files, and recurses into + `rmdir`s subdirectories - sequential (one command in flight at a time)
- `open_remote_file(remote_path, callback)` - Download and open in buffer (reports success only after `:edit` succeeds)
- `upload_current_buffer(remote_path, callback)` - Upload active buffer

**Key Design**:
- All operations are async via jobs.lua
- Downloads cached in `stdpath("cache") .. "/mpremote"` with hashed names to avoid collisions
- Upload from buffers uses temporary snapshots of in-memory lines (includes unsaved edits)
- Directory sync uses local libuv traversal + recursive remote listing, then staged apply order: conflict resolution, mkdir parent-first, upload, delete files, delete dirs child-first
- Stores remote source in buffer variable `vim.b.mpwrap_source`
- Parses `mpremote fs ls` output into entry tables

---

#### `repl.lua`
**Purpose**: REPL terminal management

**Responsibilities**:
- Create and manage REPL terminal buffer
- Handle terminal lifecycle (start, stop, restart)
- Provide REPL interaction (send text, focus)
- Track REPL state

**Public API**:
- `create(winid)` - Create REPL in window
- `stop()` - Stop REPL and cleanup
- `is_running()` - Check if REPL is active
- `send(text)` - Send text to REPL
- `focus()` - Focus REPL window
- `restart()` - Restart REPL

**State**: Module state table with bufnr, winid, job_id

**Key Design**:
- Uses `vim.fn.termopen()` for terminal buffer
- REPL runs plain `mpremote repl` - **not** `mpremote soft-reset repl`. Chaining `soft-reset` doesn't work: it resets the board and swallows the output as a separate step *before* `repl` attaches in live passthrough mode, so the boot log is gone by the time you'd see it. Instead, if `reset_on_repl_start` (default on) is set, `create()` sends a real Ctrl-D byte (`\x04`) down the pty ~500ms after connecting - equivalent to pressing Ctrl-D manually once inside the REPL - so the reset happens while already forwarding raw serial output live, and `boot.py`/`main.py` output streams in
- Terminal mode keymap `<Esc><Esc>` for easy exit
- `stop()` swaps the window to a fresh empty buffer *before* force-deleting the old terminal buffer, not after. Force-deleting a still-displayed buffer with nothing else for Neovim to fall back to in that window closes the window itself instead of just clearing it (a real, if narrow, failure mode in a sparse session with no other buffers open) - swapping first means the delete never touches a displayed buffer, so this can't happen

---

#### `panel.lua`
**Purpose**: UI layout and window management

**Responsibilities**:
- Create the three-window split panel layout (menu + filesystem + REPL)
- Render the menu (two sections) and filesystem listing
- Handle user interactions (keymaps)
- Coordinate between devices.lua, fs.lua, and repl.lua
- Manage panel state

**Public API**:
- `open()` - Open the panel
- `close()` - Close the panel
- `toggle()` - Toggle panel visibility
- `state` - Exposed state for external access

**State**: Module state with window/buffer IDs for all three windows, cached filesystem entries, and the menu's item lists (`action_items`, `mpremote_items`, `menu_rows`)

**Key Design**:
- Three stacked windows in one vertical split column: **menu** (top), **filesystem** (middle), **REPL** (bottom). The menu window is created first (`M.state.main_winid`), then `below split` twice for filesystem and REPL - heights are measured once while the column is still a single window, then set explicitly on all three once they all exist (mirrors the original two-window sizing approach, extended for a third)
- Filesystem pane is a non-modifiable display buffer; cursor position maps to entry index (`entry_line_for_index`/`selected_entry_index`)
- Menu window uses native `cursorline` (linked to `MpWrapSelected`) for selection - no custom extmark tracking needed there, unlike the filesystem pane's entry highlighting, since every menu row is uniformly selectable
- Menu buffer has two sections rendered by `render_menu()`: **mpremote** (raw commands: soft-reset, RTC sync, `df`, `exec`) above **Actions** (general panel operations). `<CR>` dispatches via `M.state.menu_rows`, a buffer-line -> item lookup built fresh on each render, rather than fixed line-offset math, since the two sections' sizes can both vary
- `jobs.is_busy()` (see `jobs.lua`) is checked alongside "is the REPL running" in `can_run_filesystem_action()`, so a second panel action can't start while a previous one is still in flight
- Winbar titles (statusline-format `%#Group#...%*` syntax, not buffer content): menu pane shows `MicroPython Panel — <device>`, REPL pane shows `REPL — running`/`REPL — stopped` colored via `MpWrapStatusRunning`/`MpWrapStatusStopped` (linked to `DiagnosticOk`/`DiagnosticError`). Both use `MpWrapTitle` for the non-status text, matching the fs/menu panes' in-buffer headers
- `WinResized`/`VimResized` autocmds (registered once, module-load time) re-render the fs/menu panes so their divider lines track the panel's current width live, not just at the next explicit refresh
- Auto-refresh on mutations

**Rendering** (menu pane; filesystem pane keeps its previous single-section layout):
```
MicroPython Panel — /dev/cu.usbmodem1201        <- winbar, not buffer content
⚙ mpremote
────────────────────────────────────────
  [1] Soft reset device
  [2] Sync device clock (RTC)
  [3] Disk usage (df)
  [4] Run snippet (exec)...

⚡ Actions
────────────────────────────────────────
  [r] Refresh
  [u] Upload current buffer
  ...
```

---

#### `init.lua`
**Purpose**: Main entry point and public API

**Responsibilities**:
- Plugin initialization
- User command registration
- Public API surface
- Module coordination

**Public API**:
- `setup(opts)` - Initialize plugin
- Exposes submodules: `config`, `panel`, `repl`, `fs`, `jobs`, `devices` (`health` is not exposed here - `:checkhealth` auto-discovers `lua/mpwrap/health.lua` by Neovim convention, it doesn't need to go through `init.lua`)

**User Commands**:
- `:MpWrapToggle` - Toggle panel
- `:MpWrapOpen` - Open panel
- `:MpWrapClose` - Close panel
- `:MpWrapRepl` - Start/focus REPL
- `:MpWrapReplStop` - Stop REPL, freeing the serial port for filesystem actions
- `:MpWrapFs` - Focus filesystem pane
- `:MpWrapUpload [path]` - Upload buffer
- `:MpWrapDownload <remote> [local]` - Download file
- `:MpWrapVersion` - Show version
- `:MpWrapDevice` - Pick a device (`devices.pick`)

---

## Data Flow

### Opening the Panel

```
User: :MpWrapToggle
  → init.lua: command handler
    → panel.open()
      → If device = "auto"/"pick" and pick_device_on_open: devices.pick(callback)
        → mpremote connect list, vim.ui.select, sets config.get().device
      → open_after_device_selected():
        → Creates vertical split window (topmost - becomes the menu window)
        → Creates menu buffer, render_menu(), sets winbar title
        → below split → filesystem window, render_filesystem()
        → below split → REPL window, render_repl_placeholder() (REPL is
          NOT auto-started - filesystem browsing needs the serial port too,
          and mpremote is exclusive)
        → Sets final heights on all three windows now that all exist
        → ensure_resize_autocmds() (registered once, no-op after the first call)
        → refresh_fs():
          → fs.list(":", callback)
            → jobs.execute(["fs", "ls", ":"], callback)
              → jobstart(mpremote fs ls :)
              → on_exit: callback(success, output)
            → parse_ls_output(output)
            → Updates panel.state.entries
            → render_filesystem()
              → Draws UI in fs_bufnr
```

### Uploading a File

```
User: Press 'u' in filesystem pane
  → panel: keymap handler
    → fs.upload_current_buffer()
      → Gets current buffer path
      → Determines remote path
      → fs.upload(local_path, remote_path, callback)
        → jobs.execute(["fs", "cp", local, remote], callback)
          → jobstart(mpremote fs cp ...)
          → on_exit: callback(success)
        → notify user
        → refresh_fs()
          → fs.list() → render_filesystem()
```

### Opening a Remote File

```
User: Press <CR> on file entry
  → panel: open_entry()
    → Determines remote path from cursor position
    → fs.open_remote_file(remote_path, callback)
      → Creates temp file path
      → fs.download(remote_path, temp_path, callback)
        → jobs.execute(["fs", "cp", remote, local], callback)
      → on success:
        → vim.cmd("edit " .. temp_path)
        → Sets vim.b.mpwrap_source = remote_path
```

## State Management

### Global State

**config.lua**: `M.options` - Current configuration

### Module State

**panel.lua**: `M.state`
```lua
{
  is_open = boolean,
  main_winid = number,   -- topmost split; same window as menu_winid
  previous_winid = number, -- window active before the panel opened
  menu_winid = number,
  menu_bufnr = number,
  fs_winid = number,
  fs_bufnr = number,
  repl_winid = number,
  repl_bufnr = number,   -- placeholder buffer while REPL is stopped
  current_path = string,
  entries = array,       -- cached file listing
  action_items = array,  -- Actions section, rebuilt each render_menu()
  mpremote_items = array, -- mpremote section, rebuilt each render_menu()
  menu_rows = table,     -- buffer line -> item, for <CR> dispatch
}
```

**repl.lua**: `M.state`
```lua
{
  bufnr = number,
  winid = number,
  job_id = number,
}
```

### Buffer-Local State

**Downloaded files**: `vim.b.mpwrap_source` - Original remote path

## UI Components

All three panes receive buffer-local normal-mode navigation mappings.
`keys.next_section` and `keys.previous_section` cycle only through valid MPWrap
windows, wrapping at either end without entering unrelated editor splits. The
live terminal receives only normal-mode mappings, leaving terminal-insert Tab
available for MicroPython completion.

### Menu Pane

- **Buffer type**: `nofile`, non-modifiable
- **Rendering**: Two sections (mpremote, Actions), native `cursorline` for selection
- **Interaction**: Buffer-local normal mode keymaps, `<CR>` dispatches via `M.state.menu_rows`
- **Update**: Full redraw on each `render_menu()`

### Filesystem Pane

- **Buffer type**: `nofile`, non-modifiable
- **Rendering**: Text-based with emoji icons, `'wrap'` off so the divider lines aren't affected by content width
- **Interaction**: Buffer-local normal mode keymaps
- **Update**: Full redraw on each refresh, and on `WinResized`/`VimResized`

### REPL Pane

- **Buffer type**: `terminal`
- **Interaction**: Terminal mode, full terminal features
- **Lifecycle**: Managed by repl.lua; explicitly stopped (`repl.stop()`) when the panel closes, not left running
- **`'wrap'`**: Explicitly forced on - both when the window is created (covers the "REPL stopped" placeholder) and again right after `repl.create()` runs `termopen`, since termopen resets it to `nowrap` once as part of entering the terminal buffer, clobbering whatever was set beforehand

## Error Handling

### Strategy

1. **Async callbacks**: Always include `success` boolean
2. **User notifications**: Use `vim.notify()` with appropriate log levels
3. **Graceful degradation**: Check mpremote availability on setup
4. **Validation**: Check file existence, buffer validity, window validity

### Examples

```lua
-- Check mpremote exists
if not jobs.check_mpremote() then
  vim.notify("mpremote not found", vim.log.levels.WARN)
end

-- Validate windows before use
if M.state.fs_winid and vim.api.nvim_win_is_valid(M.state.fs_winid) then
  -- Use window
end

-- Async error handling
fs.upload(path, remote, function(success, error)
  if not success then
    vim.notify("Upload failed: " .. error, vim.log.levels.ERROR)
  end
end)
```

## Performance Considerations

### Async I/O

All mpremote operations are async to prevent blocking the editor:
- File operations can be slow over serial
- REPL interactions are real-time
- Large file transfers don't freeze UI

### Buffering

- stdout/stderr buffered until command completion
- Filesystem listing cached in memory
- No disk I/O except for downloads

### Resource Cleanup

- Buffers deleted on panel close
- Jobs stopped on plugin exit
- Terminal processes killed gracefully

## Extension Points

### Custom Commands

Users can call module functions directly:

```lua
local mpremote = require("mpwrap")

-- Custom upload workflow
mpremote.fs.upload("my_file.py", ":/lib/my_module.py", function(success)
  if success then
    mpremote.repl.send("import my_module")
  end
end)
```

### Custom Keybindings

Disable defaults and define custom:

```lua
require("mpwrap").setup({ keymaps = false })

vim.keymap.set("n", "<leader>mp", ":MpWrapToggle<CR>")
```

### Device Selection

Runtime device switching:

```vim
:MpWrapDevice
```

## Testing Strategy

### Automated Testing

`tests/*_spec.lua` - hand-rolled assertions (`tests/helpers.lua`'s `assert_equal`/`assert_true`), no external test framework dependency, in keeping with the plugin's "minimal dependencies" principle. `tests/run.lua` `dofile()`s every spec in one headless Neovim process and exits non-zero (`cquit`) if any failed; `scripts/test.sh` / `make test` runs it.

- `fs_spec.lua`, `config_spec.lua`, `devices_spec.lua` - unit tests for the parsers and command-building logic (`fs.lua`'s `mpremote fs ls` parser, `config.lua`'s `get_mpremote_cmd`/`validate`, `devices.lua`'s `connect list` parser)
- `panel_spec.lua` - headless coverage of `panel.lua` itself: no physical device needed (`pick_device_on_open = false`, device pointed at a nonexistent port so the background `fs.list()` refresh just fails harmlessly). Opens the real panel, asserts on window count/order/heights, winbar content, menu structure, and `<CR>`/`Tab` dispatch via `nvim_feedkeys`. One caveat worth knowing if you extend this: `nvim_win_set_cursor` does **not** fire `CursorMoved`, and neither raw window-resize APIs nor even a real `:vertical resize` Ex command reliably fire `WinResized` in a headless, no-attached-UI session - both are real Neovim behaviors (not test bugs), so assertions that depend on those autocmds having fired need an explicit `vim.cmd("doautocmd CursorMoved")` (or, for `VimResized`, actually changing `vim.o.columns`, which *does* fire reliably even headless)

### Linting/Formatting

`.luacheckrc` (globals = `{"vim"}`) and `stylua.toml` (2-space indent). `make lint` / `make format` / `make format-check` / `make check` (all three plus tests).

### CI

`.github/workflows/ci.yml` runs `make check` for pull requests and pushes to `main`, against both Neovim 0.8.3 and the current stable release.

### Manual Testing

1. **Setup**: Ensure mpremote and device connected
2. **Panel**: Open/close/toggle operations
3. **Filesystem**: List, upload, download, delete
4. **REPL**: Interactive commands, restart
5. **Edge cases**: Disconnects, invalid paths, large files

## Known Limitations

1. **Flat listing**: No tree navigation (MVP)
2. **Serial only**: No network device support
3. **No file watching**: Manual refresh required
4. **Single device**: Can't manage multiple devices simultaneously
5. **Parsing fragility**: Depends on mpremote output format
6. **`exec` snippets block the UI thread's job queue**: the mpremote-section "Run snippet" action has a 15s watchdog (`vim.fn.jobstop` if it hasn't returned), since there's no way to cancel a hung/looping device-side snippet from the UI otherwise

## Future Enhancements

See README.md Roadmap section for planned features.

## Debugging

Start here:

```vim
:checkhealth mpwrap
```

Enable Neovim messages:

```vim
:messages        " View notification history
:set verbose=1   " Enable verbose output
```

Inspect state:

```lua
:lua print(vim.inspect(require("mpwrap").panel.state))
:lua print(vim.inspect(require("mpwrap").config.get()))
:lua print(require("mpwrap").jobs.is_busy())  -- is an mpremote command still in flight?
```

Check jobs:

```vim
:echo jobwait([job_id], 0)  " Check if job is running
```

## Conclusion

This architecture provides a clean, maintainable foundation for MicroPython development in Neovim. The modular design allows for future enhancements while keeping the codebase simple and understandable.
