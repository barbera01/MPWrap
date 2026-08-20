# Quick Start Guide

## Installation (5 minutes)

### Step 1: Install mpremote (prerequisite)

`mpremote` is the official MicroPython CLI — this plugin only drives it, so it must work on its own first:

```bash
pipx install mpremote     # or: pip install --user mpremote / uv tool install mpremote
```

Verify the CLI, and (with your board plugged in) the connection:

```bash
mpremote --version
mpremote connect list   # should show your board's port
```

If `mpremote connect list` can't see your board, fix that before continuing — see the Prerequisites section of the README (serial permissions, drivers).

### Step 2: Install Plugin

#### Using lazy.nvim (Recommended)

Add to your `~/.config/nvim/lua/plugins/mpwrap.lua`:

```lua
return {
  "barbera01/MPWrap",
  config = function()
    require("mpwrap").setup({
      panel_width = 50,
      keymaps = true,
    })
    
    -- Recommended mappings; WhichKey uses their descriptions automatically.
    vim.keymap.set("n", "<leader>mp", "<cmd>MpWrapToggle<cr>", { desc = "Toggle panel" })
    vim.keymap.set("n", "<leader>mr", "<cmd>MpWrapRepl<cr>", { desc = "Open REPL" })
    vim.keymap.set("n", "<leader>mb", "<cmd>MpWrapSyncBuffer<cr>", { desc = "Sync buffer" })
    vim.keymap.set("n", "<leader>md", "<cmd>MpWrapSyncDir<cr>", { desc = "Sync directory" })
  end,
}
```

If you use WhichKey, add the group heading to your existing
`lua/plugins/which-key.lua` spec:

```lua
vim.list_extend(opts.spec, {
  { "<leader>m", group = "MPWrap" },
})
```

The mappings above provide the actual menu rows through their `desc` fields.

#### Using packer.nvim

Add to your `~/.config/nvim/lua/plugins.lua`:

```lua
use {
  "barbera01/MPWrap",
  config = function()
    require("mpwrap").setup()
  end
}
```

### Step 3: Restart Neovim

```bash
nvim
```

## First Use (2 minutes)

### 1. Connect Your Device

Plug in your MicroPython device via USB.

### 2. Open the Panel

In Neovim, run:
```vim
:MpWrapToggle
```

Or use your keybinding:
```
<leader>mp
```

You should see:
```
┌─────────────────────────────┬──────────────────────┐
│ MicroPython Panel — /dev/…  │                      │
│ ⚙ mpremote                  │                      │
│ ────────────────────────    │                      │
│   [1] Soft reset device     │                      │
│   [2] Sync device clock     │                      │
│   [3] Disk usage (df)       │                      │
│   [4] Run snippet (exec)... │    Your main         │
│ ⚡ Actions                   │    editing           │
│ ────────────────────────    │    window            │
│   [r] Refresh                │                      │
│   [u] Sync current buffer    │                      │
│   ...                        │                      │
├─────────────────────────────┤                      │
│ MicroPython Device  :/      │                      │
│ ────────────────────────    │                      │
│   📄 boot.py (123 bytes)    │                      │
│   📄 main.py (456 bytes)    │                      │
│   📁 lib                    │                      │
│ ────────────────────────    │                      │
│ <CR>=open D=download ...    │                      │
├─────────────────────────────┤                      │
│ REPL — stopped               │                      │
│ Press R to start the REPL    │                      │
└─────────────────────────────┴──────────────────────┘
    Menu Pane (top)                Main Window
    Filesystem Pane (middle)
    REPL Pane (bottom)
```

The panel is three stacked windows, not two — the top one is a permanently visible
menu (raw `mpremote` commands, then general panel actions), highlight a row and
press `<CR>` to run it, or use the key shown in brackets directly.

### 3. Try Basic Operations

#### View Files
The filesystem pane shows your device's files automatically.

#### Open a File
1. Navigate to a file with `j`/`k`
2. Press `<CR>` to open it
3. The file downloads to plugin cache and opens in the main window

#### Edit and Upload
1. Make changes to the file
2. Switch focus to the filesystem pane: `<C-w>w` to cycle windows, or click into it
3. Press `u` to sync current buffer
4. Done!

`u` uploads the current in-memory buffer content (including unsaved edits).

For full project mirror to device root:
```vim
:MpWrapSyncDir
```
This is destructive for remote-only files/directories and always asks confirmation.

#### Test in REPL
1. Focus the REPL pane: `:MpWrapRepl`, or `<C-w>w` to cycle to it
2. Type: `import main`
3. Press `Enter`
4. Your code runs!

> **Note:** any filesystem action (upload, delete, refresh, ...) interrupts whatever
> is currently running on the device (mpremote grabs exclusive access to do it) —
> including a running `main.py`. It doesn't restart on its own afterward. Press `x`
> in the menu pane ("Restart device") to bring it back up before testing.

#### Create a Directory
1. In filesystem pane, press `m`
2. Enter directory name: `lib`
3. Press `Enter`

#### Delete a File
1. Navigate to file with `j`/`k`
2. Press `dd` to delete it (confirm with `Yes`)

Or, to keep a local copy: `D` downloads to a local path, `M` does the same then
deletes the remote copy.

If the destination local file already exists, you'll be prompted before overwrite.

#### Clear Everything / Restart

In the menu pane: `C` recursively deletes every file in the current remote
directory (confirm first — this is irreversible), `x` restarts the device.

## Common Workflows

### Workflow 1: Quick Edit

```
:MpWrapToggle          # Open panel
[navigate to file]       # Use j/k
<CR>                     # Open file
[edit file]              # Make changes
u                        # Upload (in fs pane)
x                        # Restart device (fs actions interrupt anything running)
:MpWrapRepl            # Jump to REPL, watch it boot
import main<Enter>       # Test your code
```

### Workflow 2: Create New File

```
:edit ~/myproject/led.py       # Create file locally
[write your code]              # Edit it
:MpWrapSyncBuffer :/led.py   # Sync to device
:MpWrapToggle                # Open panel to verify
r                              # Refresh listing
```

### Workflow 3: Backup All Files

```
:MpWrapToggle                # Open panel
[for each file]
  <CR>                         # Open
  :saveas ~/backup/file.py     # Save locally
```

## Keyboard Cheat Sheet

### Global (Normal Mode)
```
<leader>mp    Toggle panel
<leader>mr    Focus REPL
:MpWrap*    All commands
```

### Menu Pane (top window — highlight + <CR>, or the key directly)
```
1/2/3/4       mpremote: soft reset / sync clock / disk usage / exec snippet
r             Refresh          u    Sync current buffer
m             Make directory   -    Parent directory
C             Clear all files  x    Restart device
R/s           Start/stop REPL  q    Close panel
```

### Filesystem Pane (Normal Mode)
```
j/k           Navigate files
<CR>          Open file
a             Focus the menu pane
D/M           Download / move to local path
dd            Delete file
```
All Menu Pane keys above also work here directly.

### REPL Pane (Terminal Mode)
```
[type code]   Execute MicroPython
<Esc><Esc>    Exit to normal mode
```

### Window Navigation
```
<C-w>w        Cycle through windows (main -> menu -> fs -> repl -> main)
<C-w>j/<C-w>k Move down/up between the panel's stacked windows
```

## Troubleshooting

Run `:checkhealth mpwrap` first — it reports your Neovim version, whether
`mpremote` is on PATH (and its version), visible devices, and whether your
config is valid, in one place.

### "mpremote not found"
Install it:
```bash
pip install mpremote
```

### "No device detected"
1. Check USB connection
2. Specify device explicitly:
```lua
require("mpwrap").setup({
  device = "/dev/ttyUSB0"  -- Linux/Mac
  -- or
  device = "COM3"          -- Windows
})
```

### "Permission denied" (Linux)
```bash
sudo usermod -a -G dialout $USER
# Log out and back in
```

### Panel doesn't open
Check for errors:
```vim
:messages
```

### Wrong device
Pick another device at runtime:
```vim
:MpWrapDevice
```

## Next Steps

1. **Read the full README**: [README.md](README.md)
2. **Explore keybindings**: [KEYBINDINGS.md](KEYBINDINGS.md)
3. **Understand architecture**: [ARCHITECTURE.md](ARCHITECTURE.md)
4. **Customize your setup**: Modify `setup()` options

## Tips

- Keep the panel open while working (it's designed for this)
- Use window navigation (`<C-w>` commands) to move around
- Any filesystem action interrupts whatever's running on the device (mpremote needs exclusive serial access) - press `x` to restart after uploading/deleting/etc. before you go test in the REPL
- Files opened from device are cached in `stdpath("cache") .. "/mpremote"` with hashed filenames to avoid collisions
- You can upload any buffer, not just ones downloaded from device

## Example Session

```vim
# 1. Start Neovim
nvim

# 2. Open panel
<leader>mp

# 3. Create a new file
:edit blink.py

# 4. Write code
i
from machine import Pin
import time

led = Pin(2, Pin.OUT)
while True:
    led.value(not led.value())
    time.sleep(0.5)
<Esc>

# 5. Save and upload
:w
<C-w>w        # Cycle to the panel's filesystem pane
u             # Upload
# Confirm destination: :/blink.py
x             # Restart device - the upload interrupted anything running

# 6. Test in REPL
:MpWrapRepl # Jump to REPL, watch it boot
import blink<Enter>
# LED should start blinking!

# 7. Stop the script
<Ctrl-C>      # In REPL

# 8. Close panel when done
q
```

## Resources

- **mpremote docs**: https://docs.micropython.org/en/latest/reference/mpremote.html
- **MicroPython**: https://micropython.org
- **Neovim**: https://neovim.io

Happy coding!
