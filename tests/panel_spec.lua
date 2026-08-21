vim.opt.runtimepath:prepend(vim.fn.getcwd())

local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local assert_match = helpers.assert_match

-- No physical device needed: skip the picker and mock all device I/O before
-- opening the panel. This keeps the public CI suite deterministic and quiet.
local config = require("mpwrap.config")
config.setup({
  device = "/dev/nonexistent",
  pick_device_on_open = false,
  keys = {
    refresh = "z",
    upload = "U",
    download = "K",
    move = "L",
    delete = "X",
    clear_all = "c",
    sync_dir = "Y",
    restart_device = "t",
    action_menu = "A",
    start_repl = "P",
    stop_repl = "S",
    open = "o",
    close_panel = "Q",
    mkdir = "N",
    parent = "H",
  },
})
local fs = require("mpwrap.fs")
local jobs = require("mpwrap.jobs")
local original_list = fs.list
local original_execute = jobs.execute

fs.list = function(_, callback)
  callback(true, {}, nil)
  return 1
end

jobs.execute = function(args, callback)
  local output = args[1] == "df" and "0 KB used" or ""
  callback(true, output, nil)
  return 1
end

local panel = require("mpwrap.panel")
local init = require("mpwrap")

panel.open()
vim.wait(300, function()
  return false
end, 50) -- let the initial async refresh settle

assert_true(panel.state.is_open, "panel should be open")
assert_true(panel.state.menu_winid and vim.api.nvim_win_is_valid(panel.state.menu_winid), "menu window should be valid")
assert_true(panel.state.fs_winid and vim.api.nvim_win_is_valid(panel.state.fs_winid), "fs window should be valid")
assert_true(panel.state.repl_winid and vim.api.nvim_win_is_valid(panel.state.repl_winid), "repl window should be valid")

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

-- Tab and Shift-Tab cycle only through menu -> filesystem -> REPL. These are
-- normal-mode mappings, including in the live terminal buffer, so terminal
-- insert-mode Tab remains available for MicroPython completion.
assert_equal(vim.api.nvim_get_current_win(), panel.state.fs_winid, "panel should initially focus filesystem")
press("<Tab>")
assert_equal(vim.api.nvim_get_current_win(), panel.state.repl_winid, "Tab should focus REPL from filesystem")
press("<Tab>")
assert_equal(vim.api.nvim_get_current_win(), panel.state.menu_winid, "Tab should wrap from REPL to menu")
press("<S-Tab>")
assert_equal(vim.api.nvim_get_current_win(), panel.state.repl_winid, "Shift-Tab should focus REPL from menu")
press("<S-Tab>")
assert_equal(vim.api.nvim_get_current_win(), panel.state.fs_winid, "Shift-Tab should focus filesystem from REPL")

-- Top-to-bottom order: menu, then fs, then repl.
local menu_row = vim.api.nvim_win_get_position(panel.state.menu_winid)[1]
local fs_row = vim.api.nvim_win_get_position(panel.state.fs_winid)[1]
local repl_row = vim.api.nvim_win_get_position(panel.state.repl_winid)[1]
assert_true(menu_row < fs_row, "menu window should be above fs window")
assert_true(fs_row < repl_row, "fs window should be above repl window")

-- Divider lines are sized to the window's current width at render time;
-- resizing the whole terminal (VimResized) should redraw them to match.
local function divider_width(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return vim.fn.strdisplaywidth(lines[2]) -- separator is always line 2
end

local original_columns = vim.o.columns
local fs_divider_before = divider_width(panel.state.fs_bufnr)
local menu_divider_before = divider_width(panel.state.menu_bufnr)

vim.o.columns = original_columns + 70
-- Headless Neovim 0.8 does not emit VimResized automatically when 'columns'
-- is assigned, so trigger the documented event explicitly.
vim.cmd("doautocmd VimResized")
vim.wait(300, function()
  return false
end, 50)

assert_true(divider_width(panel.state.fs_bufnr) > fs_divider_before, "fs divider should widen after VimResized")
assert_true(divider_width(panel.state.menu_bufnr) > menu_divider_before, "menu divider should widen after VimResized")

vim.o.columns = original_columns
vim.cmd("doautocmd VimResized")
vim.wait(300, function()
  return false
end, 50)

-- Menu window carries the overall panel title; REPL window shows its own
-- running/stopped status. Both are winbars, not buffer content, so check
-- the window option directly.
local menu_winbar = vim.wo[panel.state.menu_winid].winbar
assert_true(menu_winbar:find("MicroPython Panel", 1, true) ~= nil, "menu winbar should show the panel title")

local repl_winbar = vim.wo[panel.state.repl_winid].winbar
if repl_winbar == "" then
  vim.wait(200, function()
    return vim.wo[panel.state.repl_winid].winbar ~= ""
  end, 20)
  repl_winbar = vim.wo[panel.state.repl_winid].winbar
end
assert_true(repl_winbar:find("REPL", 1, true) ~= nil, "repl winbar should mention REPL")
assert_true(repl_winbar:find("stopped", 1, true) ~= nil, "repl winbar should show stopped before REPL is started")

-- Menu content: two sections (mpremote, then Actions), every item from
-- both present, and every selectable row resolvable via menu_rows.
local menu_lines = vim.api.nvim_buf_get_lines(panel.state.menu_bufnr, 0, -1, false)
assert_true(#panel.state.mpremote_items > 0, "mpremote_items should be populated")
assert_true(#panel.state.action_items > 0, "action_items should be populated")
assert_equal(
  #menu_lines,
  5 + #panel.state.mpremote_items + #panel.state.action_items,
  "menu buffer has both sections' header+separator+items, plus a blank line between them"
)

local function find_menu_line(label)
  for line, item in pairs(panel.state.menu_rows) do
    if item.label == label then
      return line
    end
  end
  return nil
end

for _, item in ipairs(panel.state.mpremote_items) do
  assert_true(find_menu_line(item.label) ~= nil, "menu_rows should resolve mpremote item: " .. item.label)
end
for _, item in ipairs(panel.state.action_items) do
  assert_true(find_menu_line(item.label) ~= nil, "menu_rows should resolve action item: " .. item.label)
end

-- fs pane: shows the entry-keys hint line, no embedded action list.
local fs_lines = vim.api.nvim_buf_get_lines(panel.state.fs_bufnr, 0, -1, false)
local has_hint = false
for _, line in ipairs(fs_lines) do
  if line:find("o=open", 1, true) then
    has_hint = true
  end
end
assert_true(has_hint, "fs pane should show the entry-keys hint line")

local has_custom_download = false
for _, line in ipairs(fs_lines) do
  if line:find("K=download", 1, true) then
    has_custom_download = true
  end
end
assert_true(has_custom_download, "fs hint should derive labels from configured mappings")

local found_custom_refresh = false
local found_custom_sync_dir = false
for _, item in ipairs(panel.state.action_items or {}) do
  if item.label == "Refresh" and item.key == "z" then
    found_custom_refresh = true
  end
  if item.label:find("Sync directory", 1, true) and item.key == "Y" then
    found_custom_sync_dir = true
  end
end
assert_true(found_custom_refresh, "menu labels should derive keys from configured mappings")
assert_true(found_custom_sync_dir, "menu should include sync directory action with configured key")

-- <CR> on a menu row dispatches to that row's action - tested against one
-- row from each section, since they're rendered/dispatched differently.
local function press_enter_on(label)
  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg)
    table.insert(notified, msg)
  end

  vim.api.nvim_set_current_win(panel.state.menu_winid)
  vim.api.nvim_win_set_cursor(panel.state.menu_winid, { find_menu_line(label), 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

  vim.notify = orig_notify
  return notified
end

local upload_notified = press_enter_on("Sync current buffer")
local ran_upload = false
for _, msg in ipairs(upload_notified) do
  if msg:find("Syncing", 1, true) then
    ran_upload = true
  end
end
assert_true(ran_upload, "<CR> on the Sync current buffer action row should run it")

local df_notified = press_enter_on("Disk usage (df)")
local ran_df = false
for _, msg in ipairs(df_notified) do
  if msg:find("disk usage", 1, true) then
    ran_df = true
  end
end
assert_true(ran_df, "<CR> on the mpremote df row should run it")

-- 'a' in the fs pane focuses the menu window.
vim.api.nvim_set_current_win(panel.state.fs_winid)
vim.api.nvim_feedkeys("A", "x", false)
assert_equal(vim.api.nvim_get_current_win(), panel.state.menu_winid, "'a' should focus the menu window")

-- Manual close of a panel window should reconcile/close panel state.
panel.open()
vim.wait(200, function()
  return panel.state.is_open
end, 20)

local menu_winid = panel.state.menu_winid
vim.api.nvim_win_close(menu_winid, true)
vim.wait(200, function()
  return not panel.state.is_open
end, 20)
assert_true(panel.state.is_open == false, "manual closure of a panel window should close full panel")

-- Stale callback safety: closing before async open callback must not reopen.
local original_open_remote_file = fs.open_remote_file
local stale_called = false
fs.open_remote_file = function(_remote, cb)
  stale_called = true
  vim.defer_fn(function()
    cb(true, "/tmp/stale-file.py", nil)
  end, 20)
end

panel.open()
vim.wait(200, function()
  return panel.state.is_open
end, 20)

-- Trigger open callback path, then close immediately to invalidate generation.
panel.state.entries = { { name = "test.py", type = "file" } }
vim.bo[panel.state.fs_bufnr].modifiable = true
vim.api.nvim_buf_set_lines(panel.state.fs_bufnr, 0, -1, false, {
  "title",
  "---",
  "",
  "  📄 test.py",
  "",
  "hint",
})
vim.bo[panel.state.fs_bufnr].modifiable = false
vim.api.nvim_set_current_win(panel.state.fs_winid)
vim.api.nvim_win_set_cursor(panel.state.fs_winid, { 4, 0 })
vim.api.nvim_feedkeys("o", "x", false)
panel.close()
vim.wait(100, function()
  return stale_called
end, 10)
assert_true(panel.state.is_open == false, "stale async callbacks should not reopen closed panel")
fs.open_remote_file = original_open_remote_file

panel.close()
assert_true(not panel.state.is_open, "panel should be closed")
assert_true(panel.state.menu_winid == nil, "menu_winid should be reset on close")
assert_true(panel.state.fs_winid == nil, "fs_winid should be reset on close")
assert_true(panel.state.repl_winid == nil, "repl_winid should be reset on close")

-- If target window for open_remote_file vanishes, callback should report error.
local current = vim.api.nvim_get_current_win()
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(current, scratch)
local got_success
local got_error

local original_download = fs.download
fs.download = function(_, _local_path, cb)
  cb(true)
end

local win_to_close = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
local other = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(win_to_close)
vim.api.nvim_win_close(win_to_close, true)
vim.api.nvim_set_current_win(other)

fs.open_remote_file(":/x.py", function(success, _path, err)
  got_success = success
  got_error = err
end, { local_path = vim.fn.tempname(), winid = win_to_close })

vim.wait(200, function()
  return got_success ~= nil
end, 10)
assert_true(got_success == false, "open_remote_file should fail when target window vanished")
assert_match(got_error or "", "no longer valid", "open_remote_file should explain invalid target window")
fs.download = original_download

-- Wiping the placeholder buffer should not be treated as panel corruption.
panel.open()
vim.wait(200, function()
  return panel.state.is_open
end, 20)

local placeholder_buf = panel.state.repl_bufnr
local dummy_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(panel.state.repl_winid, dummy_buf)
if placeholder_buf and vim.api.nvim_buf_is_valid(placeholder_buf) then
  vim.api.nvim_buf_delete(placeholder_buf, { force = true })
end
vim.wait(100, function()
  return false
end, 10)
assert_true(panel.state.is_open == true, "placeholder wipe during REPL start must not close panel")

-- Commands route through panel wrappers.
local start_calls = 0
local stop_calls = 0
local original_panel_start = panel.start_repl
local original_panel_stop = panel.stop_repl
panel.start_repl = function()
  start_calls = start_calls + 1
end
panel.stop_repl = function()
  stop_calls = stop_calls + 1
end

init._create_commands()
vim.cmd("MpWrapRepl")
vim.cmd("MpWrapReplStop")
assert_true(start_calls == 1, "MpWrapRepl should call panel.start_repl")
assert_true(stop_calls == 1, "MpWrapReplStop should call panel.stop_repl")

panel.start_repl = original_panel_start
panel.stop_repl = original_panel_stop
panel.close()

fs.list = original_list
jobs.execute = original_execute

print("panel_spec passed")
