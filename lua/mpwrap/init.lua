-- Main entry point for mpwrap.nvim
local M = {}

local config = require("mpwrap.config")
local panel = require("mpwrap.panel")
local repl = require("mpwrap.repl")
local fs = require("mpwrap.fs")
local jobs = require("mpwrap.jobs")
local devices = require("mpwrap.devices")

-- Setup function - call from user config
function M.setup(opts)
  -- Merge user config with defaults
  config.setup(opts)

  -- Check if mpremote is available
  if not jobs.check_mpremote() then
    vim.notify("mpremote command not found in PATH. Please install it with: pip install mpremote", vim.log.levels.WARN)
  end

  -- Create user commands
  M._create_commands()
end

-- Create user commands
function M._create_commands()
  local function recreate_user_command(name, rhs, spec)
    pcall(vim.api.nvim_del_user_command, name)
    vim.api.nvim_create_user_command(name, rhs, spec)
  end

  local function run_sync_buffer(args)
    local remote_path = args.args ~= "" and args.args or nil

    vim.notify("Syncing buffer...", vim.log.levels.INFO)
    fs.upload_current_buffer(remote_path, function(success, error)
      if success then
        vim.notify("Buffer sync successful", vim.log.levels.INFO)
      else
        vim.notify("Buffer sync failed: " .. (error or "unknown error"), vim.log.levels.ERROR)
      end
    end)
  end

  -- Toggle panel
  recreate_user_command("MpWrapToggle", function()
    panel.toggle()
  end, {
    desc = "Toggle MicroPython remote panel",
  })

  -- Open panel
  recreate_user_command("MpWrapOpen", function()
    panel.open()
  end, {
    desc = "Open MicroPython remote panel",
  })

  -- Close panel
  recreate_user_command("MpWrapClose", function()
    panel.close()
  end, {
    desc = "Close MicroPython remote panel",
  })

  -- Focus REPL
  recreate_user_command("MpWrapRepl", function()
    if panel.state.is_open and panel.state.repl_winid and vim.api.nvim_win_is_valid(panel.state.repl_winid) then
      panel.start_repl()
    else
      vim.notify("Open panel with :MpWrapOpen before starting REPL", vim.log.levels.WARN)
    end
  end, {
    desc = "Start or focus MicroPython REPL",
  })

  -- Stop REPL so mpremote filesystem commands can access the serial port
  recreate_user_command("MpWrapReplStop", function()
    if panel.state.is_open and panel.state.repl_winid and vim.api.nvim_win_is_valid(panel.state.repl_winid) then
      panel.stop_repl()
    else
      vim.notify("Open panel with :MpWrapOpen before stopping REPL", vim.log.levels.WARN)
    end
  end, {
    desc = "Stop MicroPython REPL to free serial port for filesystem actions",
  })

  -- Refresh filesystem
  recreate_user_command("MpWrapFs", function()
    if panel.state.is_open and panel.state.fs_winid and vim.api.nvim_win_is_valid(panel.state.fs_winid) then
      vim.api.nvim_set_current_win(panel.state.fs_winid)
    else
      vim.notify("Filesystem pane is not available. Open panel with :MpWrapOpen", vim.log.levels.WARN)
    end
  end, {
    desc = "Focus MicroPython filesystem pane",
  })

  -- Upload current buffer
  recreate_user_command("MpWrapSyncBuffer", run_sync_buffer, {
    desc = "Sync current buffer to device",
    nargs = "?",
  })

  -- Backward-compatible alias
  recreate_user_command("MpWrapUpload", run_sync_buffer, {
    desc = "Alias for MpWrapSyncBuffer",
    nargs = "?",
  })

  recreate_user_command("MpWrapSyncDir", function(args)
    local local_dir = args.args ~= "" and vim.fn.expand(args.args) or vim.fn.getcwd(-1, -1)

    if jobs.is_busy() then
      vim.notify("A filesystem action is already running; wait and retry", vim.log.levels.WARN)
      return
    end

    vim.notify("Planning exact directory sync to remote root...", vim.log.levels.INFO)
    fs.plan_directory_sync(local_dir, ":", {
      ignore_patterns = config.get_sync_ignore_patterns(),
    }, function(success, plan, err)
      if not success then
        vim.notify("Directory sync planning failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
      end

      local s = plan.summary or {}
      local confirm_text = table.concat({
        "Exact mirror local directory to device root (:)",
        "",
        "Local source: " .. local_dir,
        "Remote destination: :",
        "",
        string.format("Create directories: %d", s.create_dirs or 0),
        string.format("Upload files: %d", s.upload_files or 0),
        string.format("Delete remote-only files: %d", s.delete_files or 0),
        string.format("Delete remote-only directories: %d", s.delete_dirs or 0),
        string.format("Type conflicts: %d", s.type_conflicts or 0),
        string.format("Ignored local paths: %d", s.ignored or 0),
        string.format("Skipped symlinks: %d", s.skipped_symlinks or 0),
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
        if ok then
          vim.notify("Directory sync complete", vim.log.levels.INFO)
        else
          vim.notify("Directory sync failed: " .. (apply_err or "unknown error"), vim.log.levels.ERROR)
        end
      end, function(i, total, step)
        if total <= 20 or i == 1 or i == total or (i % 20 == 0) then
          vim.notify(string.format("[%d/%d] %s %s", i, total, step.kind, step.rel_path or ":"), vim.log.levels.INFO)
        end
      end)
    end)
  end, {
    desc = "Exact-mirror sync local directory to remote root",
    nargs = "?",
    complete = "dir",
  })

  -- Download file from device
  recreate_user_command("MpWrapDownload", function(args)
    if #args.fargs == 0 then
      vim.notify("Usage: MpWrapDownload <remote_path> [local_path]", vim.log.levels.ERROR)
      return
    end

    local remote_path = args.fargs[1]
    local local_path = args.fargs[2]

    if not local_path then
      -- Use current directory with same filename
      local filename = fs.remote_basename(remote_path)
      local_path = vim.fn.getcwd(-1, -1) .. "/" .. filename
    end

    vim.notify("Downloading " .. remote_path .. "...", vim.log.levels.INFO)
    local function run_download(force)
      fs.download(remote_path, local_path, function(success, error)
        if success then
          vim.notify("Downloaded to " .. local_path, vim.log.levels.INFO)
          -- Optionally open the file
          vim.ui.select({ "Yes", "No" }, {
            prompt = "Open downloaded file?",
          }, function(choice)
            if choice == "Yes" then
              vim.cmd("edit " .. vim.fn.fnameescape(local_path))
            end
          end)
        else
          vim.notify("Download failed: " .. (error or "unknown error"), vim.log.levels.ERROR)
        end
      end, { force = force })
    end

    if vim.fn.filereadable(local_path) == 1 then
      vim.ui.select({ "No", "Yes" }, {
        prompt = "Local file exists. Overwrite " .. local_path .. "?",
      }, function(choice)
        if choice == "Yes" then
          run_download(true)
        end
      end)
      return
    end

    run_download(false)
  end, {
    desc = "Download file from device",
    nargs = "+",
  })

  -- Show mpremote version
  recreate_user_command("MpWrapVersion", function()
    jobs.get_version(function(success, output)
      if success then
        vim.notify("mpremote version: " .. vim.trim(output), vim.log.levels.INFO)
      else
        vim.notify("Failed to get version", vim.log.levels.ERROR)
      end
    end)
  end, {
    desc = "Show mpremote version",
  })

  recreate_user_command("MpWrapDevice", function()
    devices.pick(function(success)
      if success and panel.state.is_open then
        vim.notify("Device changed. Close/reopen panel or refresh after stopping REPL.", vim.log.levels.INFO)
      end
    end)
  end, {
    desc = "Select MicroPython device",
  })
end

-- Expose submodules for advanced usage
M.config = config
M.panel = panel
M.repl = repl
M.fs = fs
M.jobs = jobs
M.devices = devices

return M
