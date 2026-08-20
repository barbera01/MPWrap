-- Panel UI management
local M = {}
local config = require("mpwrap.config")
local devices = require("mpwrap.devices")
local fs = require("mpwrap.fs")
local jobs = require("mpwrap.jobs")
local repl = require("mpwrap.repl")

-- Panel state
M.state = {
  is_open = false,
  main_winid = nil, -- Main panel window (topmost split; becomes the menu window)
  previous_winid = nil, -- Window that was active before opening panel
  menu_winid = nil, -- Action menu window (top)
  menu_bufnr = nil, -- Action menu buffer
  fs_winid = nil, -- Filesystem pane window (middle)
  fs_bufnr = nil, -- Filesystem buffer
  repl_winid = nil, -- REPL pane window (bottom)
  repl_bufnr = nil, -- Placeholder REPL buffer when terminal is stopped
  current_path = ":", -- Current remote path
  entries = {}, -- Cached file entries
  action_items = nil, -- Action items for the current menu render (see get_action_items)
  mpremote_items = nil, -- Raw mpremote-command items (see get_mpremote_items)
  menu_rows = nil, -- 1-based buffer line -> selectable item, across both menu sections
  last_sync_dir = nil, -- Remembered directory sync source, so prompt_sync_directory() only needs re-confirming
  opening = false,
  open_generation = 0,
  closing = false,
}

local ns = vim.api.nvim_create_namespace("mpwrap_panel")
local ns_sel = vim.api.nvim_create_namespace("mpwrap_panel_sel")
local header_lines = 3
local last_selected_line = nil
local resize_autocmds_registered = false
local lifecycle_autocmds_registered = false

-- Forward-declared: assigned further down in this file, once the action
-- functions (refresh_fs, upload_buffer, ...) it references are defined.
-- render_menu (defined before those) calls it through this upvalue.
local get_action_items

-- Same idea, for the raw mpremote-command section of the menu.
local get_mpremote_items
local render_menu

local function current_open_generation()
  return M.state.open_generation
end

local function bump_open_generation()
  M.state.open_generation = M.state.open_generation + 1
  return M.state.open_generation
end

local function is_panel_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:match("^mpwrap://") ~= nil
end

local function is_panel_win(winid)
  return winid == M.state.menu_winid or winid == M.state.fs_winid or winid == M.state.repl_winid
end

local function update_previous_edit_winid()
  local winid = vim.api.nvim_get_current_win()
  if is_panel_win(winid) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  if is_panel_buf(bufnr) then
    return
  end
  M.state.previous_winid = winid
end

local function set_current_path(path)
  if M.state.current_path == path then
    return
  end
  M.state.current_path = path
  render_menu()
end

local function format_sync_plan_summary(plan)
  local s = plan.summary or {}
  return table.concat({
    string.format("Create directories: %d", s.create_dirs or 0),
    string.format("Upload files: %d", s.upload_files or 0),
    string.format("Delete remote-only files: %d", s.delete_files or 0),
    string.format("Delete remote-only directories: %d", s.delete_dirs or 0),
    string.format("Type conflicts: %d", s.type_conflicts or 0),
    string.format("Ignored local paths: %d", s.ignored or 0),
    string.format("Skipped symlinks: %d", s.skipped_symlinks or 0),
  }, "\n")
end

local function set_highlights()
  vim.api.nvim_set_hl(0, "MpWrapTitle", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "MpWrapBorder", { default = true, link = "FloatBorder" })
  vim.api.nvim_set_hl(0, "MpWrapDirectory", { default = true, link = "Directory" })
  vim.api.nvim_set_hl(0, "MpWrapFile", { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, "MpWrapSize", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "MpWrapHelp", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "MpWrapSelected", { default = true, link = "Visual" })
  vim.api.nvim_set_hl(0, "MpWrapStatusRunning", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "MpWrapStatusStopped", { default = true, link = "DiagnosticError" })
end

local function entry_line_for_index(index)
  return header_lines + index
end

local function selected_entry_index()
  if not M.state.fs_winid or not vim.api.nvim_win_is_valid(M.state.fs_winid) then
    return nil
  end

  local line = vim.api.nvim_win_get_cursor(M.state.fs_winid)[1]
  local idx = line - header_lines

  if idx >= 1 and idx <= #M.state.entries then
    return idx
  end

  return nil
end

-- Apply static highlights: title, border, entries, hint line.
-- Called once per render — not on every cursor move.
local function apply_static_highlights()
  if not M.state.fs_bufnr or not vim.api.nvim_buf_is_valid(M.state.fs_bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(M.state.fs_bufnr, ns, 0, -1)

  vim.api.nvim_buf_add_highlight(M.state.fs_bufnr, ns, "MpWrapTitle", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(M.state.fs_bufnr, ns, "MpWrapBorder", 1, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(M.state.fs_bufnr)
  vim.api.nvim_buf_add_highlight(M.state.fs_bufnr, ns, "MpWrapHelp", line_count - 1, 0, -1)

  for index, entry in ipairs(M.state.entries) do
    local line = entry_line_for_index(index) - 1
    local group = entry.type == "dir" and "MpWrapDirectory" or "MpWrapFile"
    vim.api.nvim_buf_add_highlight(M.state.fs_bufnr, ns, group, line, 2, -1)

    if entry.size then
      local text = vim.api.nvim_buf_get_lines(M.state.fs_bufnr, line, line + 1, false)[1] or ""
      local size_start = text:find("%(%d+ bytes%)")
      if size_start then
        vim.api.nvim_buf_add_highlight(M.state.fs_bufnr, ns, "MpWrapSize", line, size_start - 1, -1)
      end
    end
  end
end

-- Update only the moving selection extmark. Skips work when the cursor
-- hasn't changed lines, since CursorMoved fires on every character.
local function update_selection_highlight()
  if not M.state.fs_bufnr or not vim.api.nvim_buf_is_valid(M.state.fs_bufnr) then
    return
  end

  local selected = selected_entry_index()
  local new_line = selected and (entry_line_for_index(selected) - 1) or nil

  if new_line == last_selected_line then
    return
  end
  last_selected_line = new_line

  vim.api.nvim_buf_clear_namespace(M.state.fs_bufnr, ns_sel, 0, -1)

  if new_line then
    pcall(vim.api.nvim_buf_set_extmark, M.state.fs_bufnr, ns_sel, new_line, 0, {
      line_hl_group = "MpWrapSelected",
    })
  end
end

-- mpremote opens serial ports exclusively. Filesystem commands cannot run while
-- the embedded REPL owns the serial device, so fail fast with a clear message.
-- Also refuse to start a new one while another mpremote subprocess (from a
-- previous panel action) is still in flight - overlapping invocations
-- silently corrupt or half-complete one of them.
local function can_run_filesystem_action()
  if repl.is_running() then
    vim.notify(
      "Stop the mpremote REPL before filesystem actions. Press 's' in the panel or run :MpWrapReplStop, then retry.",
      vim.log.levels.WARN
    )
    return false
  end

  if jobs.is_busy() then
    vim.notify(
      "The serial device is still busy - wait for the current operation to finish and retry.",
      vim.log.levels.WARN
    )
    return false
  end

  return true
end

-- Render filesystem entries in buffer
local function render_filesystem()
  if not M.state.fs_bufnr or not vim.api.nvim_buf_is_valid(M.state.fs_bufnr) then
    return
  end

  -- Make buffer modifiable
  vim.bo[M.state.fs_bufnr].modifiable = true

  local width = 40
  if M.state.fs_winid and vim.api.nvim_win_is_valid(M.state.fs_winid) then
    width = math.max(40, vim.api.nvim_win_get_width(M.state.fs_winid) - 2)
  end

  local lines = {}
  table.insert(lines, "󰀻 MicroPython Device  " .. M.state.current_path)
  table.insert(lines, string.rep("─", width))
  table.insert(lines, "")

  if #M.state.entries == 0 then
    table.insert(lines, "  [Empty or loading...]")
  else
    for _, entry in ipairs(M.state.entries) do
      local icon = entry.type == "dir" and "📁" or "📄"
      local size = entry.size and string.format(" (%d bytes)", entry.size) or ""
      table.insert(lines, string.format("  %s %s%s", icon, entry.name, size))
    end
  end

  table.insert(lines, "")
  table.insert(lines, string.rep("─", width))
  local keys = config.get().keys
  table.insert(
    lines,
    string.format("  %s=open  %s=download  %s=move  %s=delete", keys.open, keys.download, keys.move, keys.delete)
  )

  vim.api.nvim_buf_set_lines(M.state.fs_bufnr, 0, -1, false, lines)
  vim.bo[M.state.fs_bufnr].modifiable = false

  last_selected_line = nil -- force selection redraw after content change
  apply_static_highlights()
  update_selection_highlight()
end

-- Keep the REPL window's winbar in sync with whether the REPL is actually
-- running. It's a window-local option, so it persists across the
-- placeholder-buffer <-> live-terminal-buffer swaps in that same window -
-- this just needs to be re-set after each state change, not continuously.
local function update_repl_winbar()
  if not M.state.repl_winid or not vim.api.nvim_win_is_valid(M.state.repl_winid) then
    return
  end

  local running = repl.is_running()
  local status = running and "running" or "stopped"
  local hl_group = running and "MpWrapStatusRunning" or "MpWrapStatusStopped"
  -- winbar uses 'statusline' format syntax: %#Group# switches highlight,
  -- %* resets back to the winbar's default highlighting. "REPL" itself
  -- uses MpWrapTitle, matching the fs/menu pane headers; only the
  -- running/stopped word gets the status color.
  vim.wo[M.state.repl_winid].winbar = string.format("%%#MpWrapTitle#  REPL —%%* %%#%s#%s%%*", hl_group, status)
end

local function render_repl_placeholder()
  if not M.state.repl_winid or not vim.api.nvim_win_is_valid(M.state.repl_winid) then
    return
  end

  if not M.state.repl_bufnr or not vim.api.nvim_buf_is_valid(M.state.repl_bufnr) then
    M.state.repl_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[M.state.repl_bufnr].buftype = "nofile"
    vim.bo[M.state.repl_bufnr].bufhidden = "wipe"
    vim.bo[M.state.repl_bufnr].swapfile = false
    vim.bo[M.state.repl_bufnr].filetype = "mpwrap-repl-placeholder"
    vim.api.nvim_buf_set_name(M.state.repl_bufnr, "mpwrap://repl-stopped")
  end

  vim.api.nvim_win_set_buf(M.state.repl_winid, M.state.repl_bufnr)
  vim.bo[M.state.repl_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.repl_bufnr, 0, -1, false, {
    "REPL stopped",
    "",
    "Filesystem actions are available while the REPL is stopped.",
    "",
    "Press R in the filesystem pane to start the REPL.",
    "Press s in the filesystem pane to stop it again.",
  })
  vim.bo[M.state.repl_bufnr].modifiable = false

  update_repl_winbar()
end

local function start_repl()
  if repl.is_running() then
    repl.focus()
    update_repl_winbar()
    return
  end

  if not M.state.repl_winid or not vim.api.nvim_win_is_valid(M.state.repl_winid) then
    vim.notify("REPL window is not available", vim.log.levels.WARN)
    return
  end

  local ok, err = repl.create(M.state.repl_winid, {
    on_exit = function(exit_code)
      if M.state.is_open then
        render_repl_placeholder()
        if exit_code == 0 then
          vim.notify("REPL exited", vim.log.levels.INFO)
        else
          vim.notify("REPL exited with code " .. tostring(exit_code), vim.log.levels.WARN)
        end
      end
    end,
  })
  if not ok then
    vim.notify(err or "Failed to start REPL", vim.log.levels.WARN)
    render_repl_placeholder()
    return
  end
  -- termopen sets 'nowrap' once as part of entering the terminal buffer,
  -- clobbering whatever was set beforehand - so this has to happen after
  -- create(), not when the window itself was first created.
  if vim.api.nvim_win_is_valid(M.state.repl_winid) then
    vim.wo[M.state.repl_winid].wrap = true
  end
  update_repl_winbar()
end

M.start_repl = start_repl

-- Refresh filesystem listing
local function refresh_fs(opts)
  opts = opts or {}
  local generation = current_open_generation()

  if opts.require_repl_stopped ~= false and not can_run_filesystem_action() then
    return
  end

  vim.notify("Refreshing device filesystem...", vim.log.levels.INFO)

  fs.list(M.state.current_path, function(success, entries, error)
    if generation ~= current_open_generation() or not M.state.is_open then
      return
    end

    if success then
      M.state.entries = entries
      render_filesystem()
      vim.notify("Refreshed (" .. #entries .. " items)", vim.log.levels.INFO)
    else
      vim.notify("Failed to refresh: " .. (error or "unknown error"), vim.log.levels.ERROR)
    end

    if opts.after then
      opts.after(success, entries, error)
    end
  end)
end

-- Get entry under cursor
local function get_entry_at_cursor()
  local line = vim.api.nvim_win_get_cursor(M.state.fs_winid)[1]
  -- Offset for header lines (3 lines before entries start)
  local idx = line - header_lines

  if idx >= 1 and idx <= #M.state.entries then
    return M.state.entries[idx]
  end
  return nil
end

-- Open file under cursor
local function open_entry()
  local entry = get_entry_at_cursor()
  if not entry then
    vim.notify("No file selected", vim.log.levels.WARN)
    return
  end

  if entry.type == "dir" then
    set_current_path(fs.join_remote_path(M.state.current_path, entry.name))
    refresh_fs()
    return
  end

  local remote_path = fs.join_remote_path(M.state.current_path, entry.name)
  local generation = current_open_generation()

  if not can_run_filesystem_action() then
    return
  end

  vim.notify("Downloading " .. entry.name .. "...", vim.log.levels.INFO)
  local target_winid = M.state.previous_winid
  if not target_winid or not vim.api.nvim_win_is_valid(target_winid) then
    target_winid = nil
  end

  fs.open_remote_file(remote_path, function(success, local_path, error)
    if generation ~= current_open_generation() or not M.state.is_open then
      return
    end

    if not success then
      vim.notify("Failed to open: " .. (error or "unknown error"), vim.log.levels.ERROR)
    else
      vim.notify("Opened " .. local_path, vim.log.levels.INFO)
    end
  end, {
    winid = target_winid,
  })
end

-- Delete entry under cursor
local function delete_entry()
  local entry = get_entry_at_cursor()
  if not entry then
    vim.notify("No file selected", vim.log.levels.WARN)
    return
  end

  -- Confirm deletion
  local response = vim.fn.confirm("Delete " .. entry.name .. "?", "&Yes\n&No", 2)
  if response ~= 1 then
    return
  end

  local remote_path = fs.join_remote_path(M.state.current_path, entry.name)

  if not can_run_filesystem_action() then
    return
  end

  vim.notify("Deleting " .. entry.name .. "...", vim.log.levels.INFO)
  local generation = current_open_generation()
  fs.delete(remote_path, function(success, error)
    if generation ~= current_open_generation() or not M.state.is_open then
      return
    end
    if success then
      vim.notify("Deleted " .. entry.name, vim.log.levels.INFO)
      refresh_fs()
    else
      vim.notify("Failed to delete: " .. (error or "unknown error"), vim.log.levels.ERROR)
    end
  end)
end

-- Download or move the selected remote file to a local destination.
local function transfer_entry_to_local(delete_after_download)
  local entry = get_entry_at_cursor()
  if not entry then
    vim.notify("No file selected", vim.log.levels.WARN)
    return
  end

  if entry.type == "dir" then
    vim.notify("Downloading directories is not supported yet", vim.log.levels.WARN)
    return
  end

  local remote_path = fs.join_remote_path(M.state.current_path, entry.name)
  local default_path = vim.fn.getcwd(-1, -1) .. "/" .. fs.remote_basename(entry.name)
  local action = delete_after_download and "Move" or "Download"

  vim.ui.input({
    prompt = action .. " to local path: ",
    default = default_path,
    completion = "file",
  }, function(local_path)
    local generation = current_open_generation()

    if not local_path or local_path == "" then
      return
    end

    local_path = vim.fn.expand(local_path)
    if vim.fn.isdirectory(local_path) == 1 then
      local_path = local_path .. "/" .. entry.name
    end

    if not can_run_filesystem_action() then
      return
    end

    local function perform_download(force)
      vim.notify(action .. "ing " .. entry.name .. "...", vim.log.levels.INFO)
      fs.download(remote_path, local_path, function(success, error)
        if generation ~= current_open_generation() or not M.state.is_open then
          return
        end

        if not success then
          vim.notify(action .. " failed: " .. (error or "unknown error"), vim.log.levels.ERROR)
          return
        end

        if not delete_after_download then
          vim.notify("Downloaded to " .. local_path, vim.log.levels.INFO)
          return
        end

        fs.delete(remote_path, function(delete_success, delete_error)
          if generation ~= current_open_generation() or not M.state.is_open then
            return
          end

          if delete_success then
            vim.notify("Moved to " .. local_path, vim.log.levels.INFO)
            refresh_fs()
          else
            vim.notify(
              "Downloaded to " .. local_path .. ", but failed to delete remote: " .. (delete_error or "unknown error"),
              vim.log.levels.ERROR
            )
          end
        end)
      end, { force = force })
    end

    if vim.fn.filereadable(local_path) == 1 then
      vim.ui.select({ "No", "Yes" }, {
        prompt = action .. " target exists. Overwrite " .. local_path .. "?",
      }, function(choice)
        if choice == "Yes" then
          perform_download(true)
        end
      end)
      return
    end

    perform_download(false)
  end)
end

-- Upload current buffer to device
local function upload_buffer()
  vim.notify("Syncing current buffer...", vim.log.levels.INFO)

  if not can_run_filesystem_action() then
    return
  end

  local target_winid = M.state.previous_winid
  if not target_winid or not vim.api.nvim_win_is_valid(target_winid) then
    vim.notify("No active editing window available to upload from", vim.log.levels.WARN)
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(target_winid)

  local generation = current_open_generation()
  fs.upload_buffer(bufnr, nil, function(success, error)
    if generation ~= current_open_generation() or not M.state.is_open then
      return
    end
    if success then
      vim.notify("Buffer sync complete", vim.log.levels.INFO)
      refresh_fs()
    else
      vim.notify("Buffer sync failed: " .. (error or "unknown error"), vim.log.levels.ERROR)
    end
  end)
end

local function sync_directory(local_dir)
  local generation = current_open_generation()
  local root_local = local_dir or vim.fn.getcwd(-1, -1)

  if not can_run_filesystem_action() then
    return
  end

  vim.notify("Planning exact directory sync to remote root...", vim.log.levels.INFO)
  fs.plan_directory_sync(root_local, ":", {
    ignore_patterns = config.get_sync_ignore_patterns(),
  }, function(success, plan, err)
    if generation ~= current_open_generation() or not M.state.is_open then
      return
    end

    if not success then
      vim.notify("Directory sync planning failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    local confirm_text = table.concat({
      "Exact mirror local directory to device root (:)",
      "",
      "Local source: " .. root_local,
      "Remote destination: :",
      "",
      format_sync_plan_summary(plan),
      "",
      "WARNING: remote-only files/directories will be permanently deleted.",
      "Proceed?",
    }, "\n")

    local response = vim.fn.confirm(confirm_text, "&Yes\n&No", 2)
    if response ~= 1 then
      vim.notify("Directory sync cancelled", vim.log.levels.INFO)
      return
    end

    vim.notify("Applying exact directory sync...", vim.log.levels.INFO)
    fs.apply_directory_sync(plan, function(ok, apply_err)
      if generation ~= current_open_generation() or not M.state.is_open then
        return
      end
      if ok then
        set_current_path(":")
        vim.notify("Directory sync complete", vim.log.levels.INFO)
        refresh_fs()
      else
        vim.notify("Directory sync failed: " .. (apply_err or "unknown error"), vim.log.levels.ERROR)
      end
    end, function(i, total, step)
      if generation ~= current_open_generation() or not M.state.is_open then
        return
      end
      if total <= 20 or i == 1 or i == total or (i % 20 == 0) then
        vim.notify(string.format("[%d/%d] %s %s", i, total, step.kind, step.rel_path or ":"), vim.log.levels.INFO)
      end
    end)
  end)
end

M.sync_directory = sync_directory

local function normalize_dir(path)
  local real = vim.loop.fs_realpath(path)
  if real then
    return real
  end
  return vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("(.)/$", "%1")
end

local function list_subdirectories(dir)
  local handle = vim.loop.fs_scandir(dir)
  if not handle then
    return {}
  end

  local dirs = {}
  while true do
    local name, ftype = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    -- Hidden dirs (.git, .venv, ...) are almost never a sync source and
    -- just add noise; still reachable via "[Type a path manually]" below.
    if ftype == "directory" and name:sub(1, 1) ~= "." then
      table.insert(dirs, name)
    end
  end
  table.sort(dirs)
  return dirs
end

-- Breadcrumb directory browser built on vim.ui.select (same primitive
-- devices.lua already uses for the device picker), so it automatically
-- upgrades if the user has telescope-ui-select/dressing/snacks etc.
-- installed, and degrades to Neovim's builtin inputlist() otherwise - no
-- new dependency either way.
local function browse_directory(start_dir, callback)
  local function show(current_dir)
    current_dir = normalize_dir(current_dir)

    local items = {
      { kind = "select", label = "[Use this directory]" },
    }

    local parent = vim.fn.fnamemodify(current_dir, ":h")
    if parent ~= current_dir then
      table.insert(items, { kind = "dir", label = ".. (" .. parent .. ")", path = parent })
    end

    for _, name in ipairs(list_subdirectories(current_dir)) do
      table.insert(items, { kind = "dir", label = name .. "/", path = current_dir .. "/" .. name })
    end

    table.insert(items, { kind = "manual", label = "[Type a path manually]" })

    vim.ui.select(items, {
      prompt = "Sync source: " .. current_dir,
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      if not choice then
        callback(nil)
        return
      end

      if choice.kind == "select" then
        callback(current_dir)
      elseif choice.kind == "dir" then
        show(choice.path)
      elseif choice.kind == "manual" then
        vim.ui.input({
          prompt = "Sync local directory to device root (:): ",
          default = current_dir,
          completion = "dir",
        }, function(input)
          if not input or vim.trim(input) == "" then
            callback(nil)
            return
          end
          callback(normalize_dir(vim.trim(input)))
        end)
      end
    end)
  end

  show(start_dir)
end

M.browse_directory = browse_directory

-- Pick the local directory to sync, since the plugin's cwd (wherever
-- Neovim was started) is not necessarily where the device code actually
-- lives - e.g. Neovim opened at a repo root while the MicroPython files sit
-- in a subdirectory. Defaults to the last directory synced this session, or
-- cwd on first use, so repeat syncs are usually just two <CR>s (confirm the
-- starting directory, then confirm the sync itself).
local function prompt_sync_directory()
  local generation = current_open_generation()
  local default_dir = M.state.last_sync_dir or vim.fn.getcwd(-1, -1)

  browse_directory(default_dir, function(selected)
    if generation ~= current_open_generation() or not M.state.is_open then
      return
    end

    if not selected then
      vim.notify("Directory sync cancelled", vim.log.levels.INFO)
      return
    end

    if vim.fn.isdirectory(selected) ~= 1 then
      vim.notify("Not a directory: " .. selected, vim.log.levels.ERROR)
      return
    end

    M.state.last_sync_dir = selected
    sync_directory(selected)
  end)
end

M.prompt_sync_directory = prompt_sync_directory

-- Create directory
local function create_directory()
  vim.ui.input({ prompt = "Directory name: " }, function(name)
    if not name or name == "" then
      return
    end

    local remote_path = fs.join_remote_path(M.state.current_path, name)

    if not can_run_filesystem_action() then
      return
    end

    vim.notify("Creating directory " .. name .. "...", vim.log.levels.INFO)
    local generation = current_open_generation()
    fs.mkdir(remote_path, function(success, error)
      if generation ~= current_open_generation() or not M.state.is_open then
        return
      end
      if success then
        vim.notify("Created directory " .. name, vim.log.levels.INFO)
        refresh_fs()
      else
        vim.notify("Failed to create directory: " .. (error or "unknown error"), vim.log.levels.ERROR)
      end
    end)
  end)
end

-- Navigate to the parent directory.
local function go_parent_directory()
  local parent = fs.parent_remote_path(M.state.current_path)
  if parent == M.state.current_path then
    vim.notify("Already at remote root", vim.log.levels.INFO)
    return
  end

  set_current_path(parent)
  refresh_fs()
end

-- Recursively delete everything in the current remote directory.
local function clear_all_files()
  if not can_run_filesystem_action() then
    return
  end

  local path = M.state.current_path
  local response = vim.fn.confirm("Delete ALL files in " .. path .. "? This cannot be undone.", "&Yes\n&No", 2)
  if response ~= 1 then
    return
  end

  vim.notify("Clearing " .. path .. "...", vim.log.levels.INFO)
  local generation = current_open_generation()
  fs.clear_directory(path, function(success, error)
    if generation ~= current_open_generation() or not M.state.is_open then
      return
    end
    if success then
      vim.notify("Cleared " .. path, vim.log.levels.INFO)
      refresh_fs()
    else
      vim.notify("Failed to clear: " .. (error or "unknown error"), vim.log.levels.ERROR)
    end
  end)
end

-- Reset the device so main.py (and whatever it runs, e.g. a web server)
-- restarts from flash. Needed because every mpremote fs/exec command
-- interrupts whatever program is currently running on the device to grab
-- the raw REPL, but never restarts it afterward - so after any filesystem
-- action in this panel, a running main.py stays dead until this runs (or
-- the REPL pane is soft-reset).
local function restart_device()
  if not can_run_filesystem_action() then
    return
  end

  vim.notify("Restarting device...", vim.log.levels.INFO)
  jobs.execute({ "reset" }, function(success, _, errors)
    if success then
      vim.notify(
        "Device restarted. Note: any further filesystem action here will stop it again until you restart once more.",
        vim.log.levels.INFO
      )
    else
      vim.notify("Restart failed: " .. (errors or "unknown error"), vim.log.levels.ERROR)
    end
  end)
end

local function stop_repl()
  if repl.is_running() then
    repl.stop({ replacement_buf = M.state.repl_bufnr })
    render_repl_placeholder()
    vim.notify("REPL stopping; filesystem actions unlock when the serial process exits.", vim.log.levels.INFO)
  else
    render_repl_placeholder()
    vim.notify("REPL is already stopped", vim.log.levels.INFO)
  end
end

M.stop_repl = stop_repl

-- Raw mpremote commands not otherwise wrapped by a panel action, rendered
-- as their own section above Actions in the menu window. Assigned here
-- (rather than declared local) because it was forward-declared near the
-- top of this file, before these dependencies existed.
function get_mpremote_items()
  -- exec can block indefinitely if the snippet itself blocks/loops on the
  -- device, with no other way to cancel from this UI - stop it after a
  -- timeout so a bad snippet can't wedge every other filesystem action.
  local function run_bounded(args, on_done)
    local finished = false
    local generation = current_open_generation()
    local job_id
    job_id = jobs.execute(args, function(success, output, errors)
      if finished then
        return
      end
      finished = true
      if generation ~= current_open_generation() or not M.state.is_open then
        return
      end
      on_done(success, output, errors)
    end)
    vim.defer_fn(function()
      if finished then
        return
      end
      finished = true
      vim.fn.jobstop(job_id)
      vim.notify("Command timed out after 15s and was stopped", vim.log.levels.WARN)
    end, 15000)
  end

  return {
    {
      key = "1",
      label = "Soft reset device",
      run = function()
        if not can_run_filesystem_action() then
          return
        end
        vim.notify("Soft-resetting device...", vim.log.levels.INFO)
        jobs.execute({ "soft-reset" }, function(success, _, errors)
          if success then
            vim.notify("Soft-reset complete", vim.log.levels.INFO)
          else
            vim.notify("Soft-reset failed: " .. (errors or "unknown error"), vim.log.levels.ERROR)
          end
        end)
      end,
    },
    {
      key = "2",
      label = "Sync device clock (RTC)",
      run = function()
        if not can_run_filesystem_action() then
          return
        end
        vim.notify("Syncing device RTC to local time...", vim.log.levels.INFO)
        jobs.execute({ "rtc", "--set" }, function(success, _, errors)
          if success then
            vim.notify("Device RTC synced", vim.log.levels.INFO)
          else
            vim.notify("RTC sync failed: " .. (errors or "unknown error"), vim.log.levels.ERROR)
          end
        end)
      end,
    },
    {
      key = "3",
      label = "Disk usage (df)",
      run = function()
        if not can_run_filesystem_action() then
          return
        end
        vim.notify("Checking disk usage...", vim.log.levels.INFO)
        jobs.execute({ "df" }, function(success, output, errors)
          if success then
            vim.notify(vim.trim(output), vim.log.levels.INFO)
          else
            vim.notify("df failed: " .. (errors or "unknown error"), vim.log.levels.ERROR)
          end
        end)
      end,
    },
    {
      key = "4",
      label = "Run snippet (exec)...",
      run = function()
        if not can_run_filesystem_action() then
          return
        end
        vim.ui.input({ prompt = "Python to exec on device (blocks until it returns): " }, function(expr)
          if not expr or expr == "" then
            return
          end
          if not can_run_filesystem_action() then
            return
          end
          vim.notify("Executing on device...", vim.log.levels.INFO)
          run_bounded({ "exec", expr }, function(success, output, errors)
            if success then
              local trimmed = vim.trim(output)
              vim.notify(trimmed ~= "" and trimmed or "(no output)", vim.log.levels.INFO)
            else
              vim.notify("exec failed: " .. (errors or "unknown error"), vim.log.levels.ERROR)
            end
          end)
        end)
      end,
    },
  }
end

-- General (non entry-specific) actions, rendered as the always-visible menu
-- window by render_menu. Assigned here (rather than declared local) because
-- it was forward-declared near the top of this file, before these
-- dependencies (refresh_fs, upload_buffer, ...) existed.
function get_action_items()
  local keys = config.get().keys
  return {
    { key = keys.refresh, label = "Refresh", run = refresh_fs },
    { key = keys.upload, label = "Sync current buffer", run = upload_buffer },
    {
      key = keys.sync_dir,
      label = "Sync directory → remote root (exact mirror)",
      run = prompt_sync_directory,
    },
    { key = keys.mkdir, label = "Make directory", run = create_directory },
    { key = keys.parent, label = "Go to parent directory", run = go_parent_directory },
    { key = keys.clear_all, label = "Clear all files in " .. M.state.current_path, run = clear_all_files },
    { key = keys.restart_device, label = "Restart device", run = restart_device },
    { key = keys.start_repl, label = "Start REPL", run = start_repl },
    { key = keys.stop_repl, label = "Stop REPL", run = stop_repl },
    {
      key = keys.close_panel,
      label = "Close panel",
      run = function()
        M.close()
      end,
    },
  }
end

-- Render the always-visible menu window (top pane): raw mpremote commands
-- (top section) above general panel actions (bottom section). Both use
-- the same "[key] label" row style and native cursorline for selection;
-- <CR> dispatches via M.state.menu_rows (buffer line -> item), built here.
function render_menu()
  if not M.state.menu_bufnr or not vim.api.nvim_buf_is_valid(M.state.menu_bufnr) then
    return
  end

  vim.bo[M.state.menu_bufnr].modifiable = true

  local width = 40
  if M.state.menu_winid and vim.api.nvim_win_is_valid(M.state.menu_winid) then
    width = math.max(20, vim.api.nvim_win_get_width(M.state.menu_winid) - 2)
  end

  local mpremote_items = get_mpremote_items and get_mpremote_items() or {}
  local action_items = get_action_items and get_action_items() or {}
  M.state.mpremote_items = mpremote_items
  M.state.action_items = action_items

  local lines = {}
  local rows = {}
  local key_highlights = {} -- 0-based line -> key length, for the "[key]" dim styling
  local section_headers = {} -- 0-based line numbers of each section's header/separator

  local function add_section(title, items)
    table.insert(section_headers, #lines) -- header line (0-based)
    table.insert(lines, title)
    table.insert(section_headers, #lines) -- separator line (0-based)
    table.insert(lines, string.rep("─", width))
    for _, item in ipairs(items) do
      table.insert(lines, string.format("  [%s] %s", item.key, item.label))
      rows[#lines] = item
      key_highlights[#lines - 1] = #item.key
    end
  end

  add_section("⚙ mpremote", mpremote_items)
  table.insert(lines, "")
  add_section("⚡ Actions", action_items)

  M.state.menu_rows = rows

  vim.api.nvim_buf_set_lines(M.state.menu_bufnr, 0, -1, false, lines)
  vim.bo[M.state.menu_bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(M.state.menu_bufnr, ns, 0, -1)
  for i, line0 in ipairs(section_headers) do
    local group = (i % 2 == 1) and "MpWrapTitle" or "MpWrapBorder" -- header, then separator
    vim.api.nvim_buf_add_highlight(M.state.menu_bufnr, ns, group, line0, 0, -1)
  end
  for line0, key_len in pairs(key_highlights) do
    vim.api.nvim_buf_add_highlight(M.state.menu_bufnr, ns, "MpWrapHelp", line0, 2, 4 + key_len)
  end
end

-- Redraw the fs/menu panes (their divider lines are sized to the window's
-- current width, computed at render time) whenever their windows are
-- resized - dragging the vsplit/split border, or resizing the terminal
-- itself. Registered once at module load; the callbacks are state-driven
-- (checked against current M.state each time) rather than tied to a
-- particular open/close cycle, so they don't need to be re-registered or
-- torn down when the panel opens and closes.
local function ensure_resize_autocmds()
  if resize_autocmds_registered then
    return
  end
  resize_autocmds_registered = true

  local group = vim.api.nvim_create_augroup("mpwrap_panel_resize", { clear = true })

  local has_winresized = false
  if vim.fn.exists("##WinResized") == 1 then
    has_winresized = true
    vim.api.nvim_create_autocmd("WinResized", {
      group = group,
      callback = function()
        if not M.state.is_open then
          return
        end
        for _, winid in ipairs(vim.v.event.windows or {}) do
          if winid == M.state.fs_winid then
            render_filesystem()
          elseif winid == M.state.menu_winid then
            render_menu()
          end
        end
      end,
      desc = "Redraw mpremote panel dividers on window resize",
    })
  end

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not M.state.is_open then
        return
      end
      render_filesystem()
      render_menu()
    end,
    desc = has_winresized and "Redraw mpremote panel dividers on terminal resize"
      or "Redraw mpremote panel dividers on resize (WinResized fallback)",
  })
end

local function ensure_lifecycle_autocmds()
  if lifecycle_autocmds_registered then
    return
  end
  lifecycle_autocmds_registered = true

  local group = vim.api.nvim_create_augroup("mpwrap_panel_lifecycle", { clear = true })

  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = group,
    callback = function()
      update_previous_edit_winid()
    end,
    desc = "Track latest non-panel editing window",
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      if not M.state.is_open or M.state.closing then
        return
      end

      local closed = tonumber(args.match)
      if not closed or not is_panel_win(closed) then
        return
      end

      vim.schedule(function()
        if M.state.is_open and not M.state.closing then
          M.close({ reason = "Panel window closed" })
        end
      end)
    end,
    desc = "Close remaining mpwrap panel windows when one is manually closed",
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      if not M.state.is_open or M.state.closing then
        return
      end
      if args.buf == M.state.menu_bufnr or args.buf == M.state.fs_bufnr then
        vim.schedule(function()
          if M.state.is_open and not M.state.closing then
            M.close({ reason = "Panel buffer wiped" })
          end
        end)
      end
    end,
    desc = "Close remaining panel state when a panel buffer is wiped",
  })
end

-- Run whichever row the cursor is on in the menu window (either section).
local function run_menu_selection()
  if not M.state.menu_winid or not vim.api.nvim_win_is_valid(M.state.menu_winid) then
    return
  end

  local line = vim.api.nvim_win_get_cursor(M.state.menu_winid)[1]
  local item = M.state.menu_rows and M.state.menu_rows[line]
  if item then
    item.run()
  end
end

-- Focus the menu window (bound to 'a' in the fs pane).
local function focus_menu()
  if M.state.menu_winid and vim.api.nvim_win_is_valid(M.state.menu_winid) then
    vim.api.nvim_set_current_win(M.state.menu_winid)
  end
end

-- Setup menu buffer keymaps
local function setup_menu_keymaps()
  if not M.state.menu_bufnr then
    return
  end

  local cfg = config.get()
  if not cfg.keymaps then
    return
  end

  local opts = { buffer = M.state.menu_bufnr, noremap = true, silent = true }

  vim.keymap.set("n", "<CR>", run_menu_selection, opts)
  -- Direct digit keys for the mpremote section (populated by render_menu,
  -- which always runs before this). Not in cfg.keys - these are menu-only,
  -- not mirrored as fs-pane keys the way the Actions section's are.
  for _, item in ipairs(M.state.mpremote_items or {}) do
    vim.keymap.set("n", item.key, item.run, opts)
  end
  -- Same direct keys as the fs pane, usable from here too.
  vim.keymap.set("n", cfg.keys.refresh, refresh_fs, opts)
  vim.keymap.set("n", cfg.keys.upload, upload_buffer, opts)
  vim.keymap.set("n", cfg.keys.sync_dir, prompt_sync_directory, opts)
  vim.keymap.set("n", cfg.keys.mkdir, create_directory, opts)
  vim.keymap.set("n", cfg.keys.parent, go_parent_directory, opts)
  vim.keymap.set("n", cfg.keys.clear_all, clear_all_files, opts)
  vim.keymap.set("n", cfg.keys.restart_device, restart_device, opts)
  vim.keymap.set("n", cfg.keys.start_repl, start_repl, opts)
  vim.keymap.set("n", cfg.keys.stop_repl, stop_repl, opts)
  vim.keymap.set("n", cfg.keys.close_panel, function()
    M.close()
  end, opts)
end

-- Setup filesystem buffer keymaps
local function setup_fs_keymaps()
  if not M.state.fs_bufnr then
    return
  end

  local cfg = config.get()
  if not cfg.keymaps then
    return
  end

  local opts = { buffer = M.state.fs_bufnr, noremap = true, silent = true }

  vim.keymap.set("n", cfg.keys.refresh, refresh_fs, opts)
  vim.keymap.set("n", cfg.keys.open, open_entry, opts)
  vim.keymap.set("n", cfg.keys.upload, upload_buffer, opts)
  vim.keymap.set("n", cfg.keys.sync_dir, prompt_sync_directory, opts)
  vim.keymap.set("n", cfg.keys.download, function()
    transfer_entry_to_local(false)
  end, opts)
  vim.keymap.set("n", cfg.keys.move, function()
    transfer_entry_to_local(true)
  end, opts)
  vim.keymap.set("n", cfg.keys.delete, delete_entry, opts)
  vim.keymap.set("n", cfg.keys.clear_all, clear_all_files, opts)
  vim.keymap.set("n", cfg.keys.restart_device, restart_device, opts)
  vim.keymap.set("n", cfg.keys.action_menu, focus_menu, opts)
  vim.keymap.set("n", cfg.keys.start_repl, start_repl, opts)
  vim.keymap.set("n", cfg.keys.stop_repl, stop_repl, opts)
  vim.keymap.set("n", cfg.keys.mkdir, create_directory, opts)
  vim.keymap.set("n", cfg.keys.parent, go_parent_directory, opts)
  vim.keymap.set("n", cfg.keys.close_panel, function()
    M.close()
  end, opts)

  vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter", "BufEnter" }, {
    buffer = M.state.fs_bufnr,
    callback = update_selection_highlight,
    desc = "Update mpwrap filesystem selection highlight",
  })
end

-- Create the panel layout: menu (top), filesystem (middle), REPL (bottom).
function M.open()
  if M.state.is_open then
    return
  end

  if M.state.opening then
    return
  end

  local cfg = config.get()
  local open_generation = bump_open_generation()
  M.state.previous_winid = vim.api.nvim_get_current_win()

  local function cleanup_partial(wins, bufs)
    for _, winid in ipairs(wins) do
      if winid and vim.api.nvim_win_is_valid(winid) then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
    for _, bufnr in ipairs(bufs) do
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end

  local function open_after_device_selected()
    if open_generation ~= current_open_generation() then
      return
    end

    M.state.opening = false

    local created_wins = {}
    local created_bufs = {}
    local ok, err = pcall(function()
      local split_cmd = cfg.panel_position == "left" and "topleft vsplit" or "botright vsplit"
      vim.cmd(split_cmd)

      M.state.main_winid = vim.api.nvim_get_current_win()
      table.insert(created_wins, M.state.main_winid)
      vim.api.nvim_win_set_width(M.state.main_winid, cfg.panel_width)

      set_highlights()

      M.state.menu_winid = M.state.main_winid
      M.state.menu_bufnr = vim.api.nvim_create_buf(false, true)
      table.insert(created_bufs, M.state.menu_bufnr)
      vim.bo[M.state.menu_bufnr].buftype = "nofile"
      vim.bo[M.state.menu_bufnr].bufhidden = "wipe"
      vim.bo[M.state.menu_bufnr].swapfile = false
      vim.bo[M.state.menu_bufnr].filetype = "mpwrap-menu"
      vim.api.nvim_buf_set_name(M.state.menu_bufnr, "mpwrap://menu")
      vim.api.nvim_win_set_buf(M.state.menu_winid, M.state.menu_bufnr)
      vim.wo[M.state.menu_winid].number = false
      vim.wo[M.state.menu_winid].relativenumber = false
      vim.wo[M.state.menu_winid].signcolumn = "no"
      vim.wo[M.state.menu_winid].cursorline = true
      vim.wo[M.state.menu_winid].winhighlight = "CursorLine:MpWrapSelected"
      vim.wo[M.state.menu_winid].wrap = false
      local shown_device = config.get_effective_device() or config.get_device_policy()
      vim.wo[M.state.menu_winid].winbar = "%#MpWrapTitle#󰀻 MicroPython Panel — " .. shown_device .. "%*"

      render_menu()
      setup_menu_keymaps()

      local total_height = vim.api.nvim_win_get_height(M.state.main_winid)
      local menu_content_lines = 5 + #(M.state.mpremote_items or {}) + #(M.state.action_items or {})
      local sep_lines = 2
      local available = math.max(total_height, 3)
      local menu_height = math.max(1, math.min(1 + menu_content_lines, math.floor(available * 0.4)))
      local repl_height = math.max(1, math.floor(available * cfg.repl_height_ratio))
      local fs_height = available - menu_height - repl_height - sep_lines

      if fs_height < 1 then
        local deficit = 1 - fs_height
        fs_height = 1
        if repl_height > 1 then
          local take = math.min(deficit, repl_height - 1)
          repl_height = repl_height - take
          deficit = deficit - take
        end
        if deficit > 0 and menu_height > 1 then
          local take = math.min(deficit, menu_height - 1)
          menu_height = menu_height - take
          deficit = deficit - take
        end
        if deficit > 0 then
          fs_height = math.max(1, fs_height - deficit)
        end
      end

      vim.cmd("below split")
      M.state.fs_winid = vim.api.nvim_get_current_win()
      table.insert(created_wins, M.state.fs_winid)
      M.state.fs_bufnr = vim.api.nvim_create_buf(false, true)
      table.insert(created_bufs, M.state.fs_bufnr)
      vim.bo[M.state.fs_bufnr].buftype = "nofile"
      vim.bo[M.state.fs_bufnr].bufhidden = "wipe"
      vim.bo[M.state.fs_bufnr].swapfile = false
      vim.bo[M.state.fs_bufnr].filetype = "mpwrap-fs"
      vim.api.nvim_buf_set_name(M.state.fs_bufnr, "mpwrap://fs")
      vim.api.nvim_win_set_buf(M.state.fs_winid, M.state.fs_bufnr)
      vim.wo[M.state.fs_winid].number = false
      vim.wo[M.state.fs_winid].relativenumber = false
      vim.wo[M.state.fs_winid].signcolumn = "no"
      vim.wo[M.state.fs_winid].cursorline = true
      vim.wo[M.state.fs_winid].wrap = false

      render_filesystem()

      vim.cmd("below split")
      M.state.repl_winid = vim.api.nvim_get_current_win()
      table.insert(created_wins, M.state.repl_winid)
      vim.wo[M.state.repl_winid].wrap = true
      render_repl_placeholder()

      pcall(vim.api.nvim_win_set_height, M.state.menu_winid, menu_height)
      pcall(vim.api.nvim_win_set_height, M.state.repl_winid, repl_height)
      pcall(vim.api.nvim_win_set_height, M.state.fs_winid, fs_height)

      vim.api.nvim_set_current_win(M.state.fs_winid)

      setup_fs_keymaps()
      ensure_resize_autocmds()
      ensure_lifecycle_autocmds()

      M.state.is_open = true
      M.state.closing = false

      refresh_fs({
        require_repl_stopped = false,
        after = function()
          if open_generation ~= current_open_generation() then
            return
          end
          if config.get().auto_start_repl and M.state.is_open then
            start_repl()
          end
        end,
      })
    end)

    if not ok then
      cleanup_partial(created_wins, created_bufs)
      M.state.main_winid = nil
      M.state.menu_winid = nil
      M.state.menu_bufnr = nil
      M.state.fs_winid = nil
      M.state.fs_bufnr = nil
      M.state.repl_winid = nil
      M.state.repl_bufnr = nil
      M.state.entries = {}
      M.state.action_items = nil
      M.state.mpremote_items = nil
      M.state.menu_rows = nil
      M.state.is_open = false
      vim.notify("Failed to open mpwrap panel: " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  local should_pick = cfg.pick_device_on_open and (cfg.device == "auto" or cfg.device == "pick")
  if should_pick then
    if cfg.device == "auto" then
      config.clear_selected_device()
    end
    M.state.opening = true
    devices.ensure_selected(function(success)
      if open_generation ~= current_open_generation() then
        return
      end
      if success then
        set_current_path(":")
        open_after_device_selected()
      else
        M.state.opening = false
      end
    end, { force_pick = cfg.device == "pick" })
  else
    set_current_path(":")
    open_after_device_selected()
  end
end

-- Close the panel
function M.close(opts)
  opts = opts or {}
  if not M.state.is_open and not M.state.opening then
    return
  end

  M.state.closing = true
  bump_open_generation()
  M.state.opening = false

  -- Stop REPL
  repl.stop({ replacement_buf = M.state.repl_bufnr })

  -- Close windows
  if M.state.repl_winid and vim.api.nvim_win_is_valid(M.state.repl_winid) then
    vim.api.nvim_win_close(M.state.repl_winid, true)
  end

  if M.state.fs_winid and vim.api.nvim_win_is_valid(M.state.fs_winid) then
    vim.api.nvim_win_close(M.state.fs_winid, true)
  end

  if M.state.menu_winid and vim.api.nvim_win_is_valid(M.state.menu_winid) then
    vim.api.nvim_win_close(M.state.menu_winid, true)
  end

  -- Delete buffers
  if M.state.fs_bufnr and vim.api.nvim_buf_is_valid(M.state.fs_bufnr) then
    vim.api.nvim_buf_delete(M.state.fs_bufnr, { force = true })
  end

  if M.state.menu_bufnr and vim.api.nvim_buf_is_valid(M.state.menu_bufnr) then
    vim.api.nvim_buf_delete(M.state.menu_bufnr, { force = true })
  end

  -- Reset state
  M.state.is_open = false
  M.state.closing = false
  M.state.main_winid = nil
  M.state.previous_winid = nil
  M.state.menu_winid = nil
  M.state.menu_bufnr = nil
  M.state.fs_winid = nil
  M.state.repl_winid = nil
  M.state.repl_bufnr = nil
  M.state.fs_bufnr = nil
  M.state.entries = {}
  M.state.action_items = nil
  M.state.mpremote_items = nil
  M.state.menu_rows = nil
  M.state.current_path = ":"

  if opts.reason then
    vim.notify(opts.reason, vim.log.levels.INFO)
  end
end

-- Toggle panel open/close
function M.toggle()
  if M.state.is_open then
    M.close()
  else
    M.open()
  end
end

return M
