# Keybindings Reference

The panel is three stacked windows: the action menu (top), the filesystem browser (middle), and the REPL (bottom).

## Panel Navigation

These buffer-local mappings work in normal mode in all three panes and wrap
without moving into unrelated editor splits:

| Key | Action |
|-----|--------|
| `<Tab>` | Focus next pane: menu → filesystem → REPL → menu |
| `<S-Tab>` | Focus previous pane |

In a live REPL, plain `<Tab>` remains available for MicroPython completion in
terminal-insert mode. Press `<Esc><Esc>` to return to normal mode before using
`<Tab>` or `<S-Tab>` to leave the REPL pane.

## Menu Pane

Two permanently visible sections, `mpremote` above `Actions`. Move the cursor onto a row (it highlights) and press `<CR>` to run it.

### mpremote section

Raw mpremote commands not otherwise wrapped by a panel action:

| Key | Action | Description |
|-----|--------|-------------|
| `1` | Soft reset | `mpremote soft-reset` |
| `2` | Sync RTC | `mpremote rtc --set` - sets the device clock to local time |
| `3` | Disk usage | `mpremote df` |
| `4` | Exec snippet | Prompts for a one-line Python snippet, runs it via `mpremote exec`. Blocks until it returns; auto-stopped after 15s if it hasn't |

### Actions section

Panel-level operations. These same keys also work directly from the filesystem pane below.

| Key | Action | Description |
|-----|--------|-------------|
| `r` | Refresh | Reload file listing from device |
| `u` | Sync buffer | Sync current buffer to device |
| `S` | Sync dir | Browse local directories (defaults to last used, else cwd) to pick a sync source, exact-mirror sync to remote root (destructive; confirm required) |
| `m` | Make directory | Create new directory on device |
| `-` | Parent | Go to parent directory |
| `C` | Clear all | Delete all files in the current remote directory (with confirmation) |
| `x` | Restart device | Reset the device so a running program (e.g. a web server) restarts |
| `R` | Start REPL | Start/focus the REPL |
| `s` | Stop REPL | Stop REPL so filesystem actions can access the serial port |
| `q` | Quit | Close the MicroPython panel |

## Default Keybindings (Filesystem Pane)

When the filesystem pane is focused, these buffer-local keybindings are active. All Menu Pane keys above also work here; the ones below act on the file/directory under the cursor:

| Key | Action | Description |
|-----|--------|-------------|
| `<CR>` | Open file | Downloads file to cache and opens in the active editing window |
| `a` | Focus menu | Move focus to the menu pane |
| `D` | Download | Download file under cursor to a local path |
| `M` | Move | Download file under cursor to a local path, then delete remote |
| `dd` | Delete | Delete file under cursor (with confirmation) |

## Terminal Mode (REPL Pane)

| Key | Action | Description |
|-----|--------|-------------|
| `<Esc><Esc>` | Exit insert | Return to normal mode from terminal insert mode |

Standard terminal mode keybindings apply in the REPL pane.

## Suggested Global Keybindings

Add these to your Neovim configuration for quick access:

```lua
vim.keymap.set("n", "<leader>mp", "<cmd>MpWrapToggle<cr>", { desc = "Toggle panel" })
vim.keymap.set("n", "<leader>mr", "<cmd>MpWrapRepl<cr>", { desc = "Open REPL" })
vim.keymap.set("n", "<leader>ms", "<cmd>MpWrapReplStop<cr>", { desc = "Stop REPL" })
vim.keymap.set("n", "<leader>mf", "<cmd>MpWrapFs<cr>", { desc = "Focus filesystem" })
vim.keymap.set("n", "<leader>mb", "<cmd>MpWrapSyncBuffer<cr>", { desc = "Sync buffer" })
vim.keymap.set("n", "<leader>md", "<cmd>MpWrapSyncDir<cr>", { desc = "Sync directory" })
vim.keymap.set("n", "<leader>mc", "<cmd>MpWrapClose<cr>", { desc = "Close panel" })
vim.keymap.set("n", "<leader>mv", "<cmd>MpWrapVersion<cr>", { desc = "Show version" })
vim.keymap.set("n", "<leader>mD", "<cmd>MpWrapDevice<cr>", { desc = "Select device" })
```

## Alternative Keybinding Schemes

### Vim-style (hjkl focus)

```lua
vim.keymap.set("n", "<leader>mt", ":MpWrapToggle<CR>")  -- Toggle
vim.keymap.set("n", "<leader>mh", ":MpWrapClose<CR>")   -- Hide/close
vim.keymap.set("n", "<leader>ml", ":MpWrapOpen<CR>")    -- Load/open
vim.keymap.set("n", "<leader>mj", ":MpWrapFs<CR>")      -- Jump to fs
vim.keymap.set("n", "<leader>mk", ":MpWrapRepl<CR>")    -- Jump to repl
```

### Minimal (single leader + m)

```lua
vim.keymap.set("n", "<leader>m", ":MpWrapToggle<CR>", { desc = "MicroPython panel" })
```

### WhichKey Integration

MPWrap does not require or configure WhichKey. WhichKey discovers normal
Neovim mappings from their `desc` fields. Based on a lazy.nvim configuration
with separate plugin files, register only the group name in
`lua/plugins/which-key.lua`:

```lua
return {
  "folke/which-key.nvim",
  opts = function(_, opts)
    opts.spec = opts.spec or {}
    vim.list_extend(opts.spec, {
      { "<leader>m", group = "MPWrap" },
    })
    return opts
  end,
}
```

Define the actual menu entries as ordinary mappings in
`lua/plugins/mpwrap.lua`, using the mappings from the previous section. For
example:

```lua
config = function()
  require("mpwrap").setup()

  vim.keymap.set("n", "<leader>mp", "<cmd>MpWrapToggle<cr>", { desc = "Toggle panel" })
  vim.keymap.set("n", "<leader>mb", "<cmd>MpWrapSyncBuffer<cr>", { desc = "Sync buffer" })
  vim.keymap.set("n", "<leader>md", "<cmd>MpWrapSyncDir<cr>", { desc = "Sync directory" })
  vim.keymap.set("n", "<leader>mr", "<cmd>MpWrapRepl<cr>", { desc = "Open REPL" })
end
```

The group declaration supplies the `MPWrap` heading; the mappings and their
`desc` values supply the rows shown after pressing `<leader>m`.

## Customizing Default Keybindings

To change the buffer-local keybindings in the filesystem pane:

```lua
require("mpwrap").setup({
  keys = {
    refresh = "R",        -- Change from 'r' to 'R'
    upload = "U",         -- Change from 'u' to 'U'
    download = "D",       -- Change from 'd' to 'D'
    delete = "dd",        -- Keep default
    open = "<CR>",        -- Keep default
    close_panel = "Q",    -- Change from 'q' to 'Q'
    mkdir = "M",          -- Change from 'm' to 'M'
  },
})
```

## Disabling Default Keybindings

To completely disable default keybindings and define your own:

```lua
require("mpwrap").setup({
  keymaps = false,
})

-- Then define your own in after/ftplugin/mpwrap-fs.lua
-- or using autocommands
vim.api.nvim_create_autocmd("FileType", {
  pattern = "mpwrap-fs",
  callback = function(ev)
    local opts = { buffer = ev.buf, noremap = true, silent = true }
    vim.keymap.set("n", "r", function()
      -- Your custom refresh logic
    end, opts)
  end,
})
```

## Common Workflows and Key Sequences

### Quick Edit Cycle

1. `<leader>mp` - Open panel
2. Navigate to file with `j`/`k`
3. `<CR>` - Open file
4. Edit file in main window
5. `<leader>mb` or switch to fs pane and press `u` - Sync buffer
6. `<leader>mr` - Jump to REPL to test

### Mass Upload

1. Open multiple files in buffers
2. `<leader>mp` - Open panel
3. For each buffer:
   - Switch to buffer
   - Press `u` in the filesystem pane (or run `:MpWrapSyncBuffer`)

### Clean Workflow

1. Keep panel open on right side
2. Edit files in main window area
3. `<C-w>l` to jump to panel
4. `u` to upload current buffer
5. `<C-w>h` to return to editing
6. Navigate to REPL with `<C-w>j` when in panel

## Tips

- **Fast navigation**: Use `<C-w>` window commands to move between panes
- **Terminal mode**: `<C-\><C-n>` is the default Neovim way to exit terminal mode (our `<Esc><Esc>` is a convenience)
- **Command mode**: You can still use `:MpWrap*` commands even when panel is open
- **Buffer focus**: Upload via `u` key uploads the most recently active non-panel editing buffer
- **Unsaved edits**: Upload uses an in-memory snapshot, so unsaved changes are included
- **Overwrite safety**: Download/move prompts before overwriting existing local files

## Troubleshooting

**Keys not working in fs pane?**
- Ensure you're in normal mode, not visual or insert
- Check that `keymaps = true` in your config

**Global keybindings conflict?**
- Choose a different leader sequence
- Use a different prefix than `<leader>m`

**Can't exit REPL?**
- Press `<Esc><Esc>` to exit terminal insert mode
- Or use `<C-\><C-n>` (standard Neovim terminal escape)
