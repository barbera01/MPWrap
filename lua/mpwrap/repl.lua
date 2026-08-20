-- REPL terminal management
local M = {}
local config = require("mpwrap.config")
local jobs = require("mpwrap.jobs")

-- State
M.state = {
  bufnr = nil,
  winid = nil,
  job_id = nil,
  lease_token = nil,
  generation = 0,
  on_exit = nil,
}

local function next_generation()
  M.state.generation = M.state.generation + 1
  return M.state.generation
end

local function clear_state_fields()
  M.state.bufnr = nil
  M.state.winid = nil
  M.state.job_id = nil
  M.state.lease_token = nil
  M.state.on_exit = nil
end

local function fail_create(message, lease_token, bufnr, winid)
  if lease_token then
    jobs.release_device_lease(lease_token)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      local placeholder = vim.api.nvim_create_buf(false, true)
      vim.bo[placeholder].bufhidden = "wipe"
      pcall(vim.api.nvim_win_set_buf, winid, placeholder)
    end
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  return false, message
end

-- Check if REPL is running
function M.is_running()
  return M.state.job_id ~= nil and vim.fn.jobwait({ M.state.job_id }, 0)[1] == -1
end

-- Create REPL terminal in specified window
-- @param winid number: Window ID to create terminal in
-- @return boolean: Success
function M.create(winid, opts)
  opts = opts or {}

  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false, "REPL target window is not available"
  end

  if M.is_running() then
    -- Already running, just focus
    if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
      vim.api.nvim_set_current_win(M.state.winid)
    end
    return true
  end

  if M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) then
    pcall(vim.api.nvim_buf_delete, M.state.bufnr, { force = true })
    M.state.bufnr = nil
  end

  local lease_token, lease_err = jobs.acquire_device_lease({ label = "REPL" })
  if not lease_token then
    vim.notify(lease_err, vim.log.levels.WARN)
    return false, lease_err
  end

  local generation = next_generation()

  -- Build mpremote repl command. mpremote's own auto soft-reset only
  -- triggers for mount/eval/exec/run/fs, never for repl, so without an
  -- explicit reset the REPL just attaches silently and any boot.py/main.py
  -- output that already happened is lost.
  --
  -- Note: chaining `mpremote soft-reset repl` does NOT work for this -
  -- `soft-reset` resets the board and swallows its output as a separate
  -- step *before* `repl` attaches in live passthrough mode, so the boot
  -- log is gone by the time you'd see it. Instead we start plain `repl`
  -- and send a real Ctrl-D byte down the pty once it has connected -
  -- equivalent to manually pressing Ctrl-D inside the REPL - so the reset
  -- happens while we're already forwarding raw serial output live.
  local cmd = config.get_mpremote_cmd({ "repl" })

  -- Set window and create terminal buffer
  local focus_ok, focus_err = pcall(vim.api.nvim_set_current_win, winid)
  if not focus_ok then
    return fail_create("REPL target window is not available: " .. tostring(focus_err), lease_token)
  end

  -- Create terminal buffer
  local create_ok, bufnr_or_err = pcall(vim.api.nvim_create_buf, false, true)
  if not create_ok then
    return fail_create("Failed to create REPL buffer: " .. tostring(bufnr_or_err), lease_token)
  end
  local bufnr = bufnr_or_err
  local set_ok, set_err = pcall(vim.api.nvim_win_set_buf, winid, bufnr)
  if not set_ok then
    return fail_create("Failed to prepare REPL buffer: " .. tostring(set_err), lease_token, bufnr, winid)
  end

  -- Start job in terminal buffer
  -- Note: termopen automatically sets buftype=terminal
  local termopen_ok, job_id_or_err = pcall(vim.fn.termopen, cmd, {
    on_exit = function(_, exit_code, _)
      vim.schedule(function()
        -- Release the physical-device lease even for a stale callback. The
        -- token check prevents an old process from releasing a newer lease.
        jobs.release_device_lease(lease_token)

        if generation ~= M.state.generation then
          return
        end

        M.state.job_id = nil
        M.state.lease_token = nil

        local on_exit = M.state.on_exit
        local exiting_bufnr = M.state.bufnr
        local exiting_winid = M.state.winid

        if on_exit then
          local callback_ok, callback_err = pcall(on_exit, exit_code)
          if not callback_ok then
            vim.notify("REPL exit callback failed: " .. tostring(callback_err), vim.log.levels.ERROR)
          end
        end

        local replaced = false
        if
          exiting_winid
          and vim.api.nvim_win_is_valid(exiting_winid)
          and exiting_bufnr
          and vim.api.nvim_buf_is_valid(exiting_bufnr)
        then
          replaced = vim.api.nvim_win_get_buf(exiting_winid) ~= exiting_bufnr
        end

        if
          not replaced
          and exiting_winid
          and vim.api.nvim_win_is_valid(exiting_winid)
          and exiting_bufnr
          and vim.api.nvim_buf_is_valid(exiting_bufnr)
        then
          local placeholder = vim.api.nvim_create_buf(false, true)
          vim.bo[placeholder].bufhidden = "wipe"
          vim.api.nvim_win_set_buf(exiting_winid, placeholder)
        end

        if exiting_bufnr and vim.api.nvim_buf_is_valid(exiting_bufnr) then
          pcall(vim.api.nvim_buf_delete, exiting_bufnr, { force = true })
        end

        M.state.bufnr = nil
        M.state.winid = nil
        M.state.on_exit = nil
      end)
    end,
  })

  if not termopen_ok then
    return fail_create("Failed to start REPL: " .. tostring(job_id_or_err), lease_token, bufnr, winid)
  end

  local job_id = job_id_or_err

  if job_id <= 0 then
    vim.notify("Failed to start REPL", vim.log.levels.ERROR)
    return fail_create("Failed to start REPL", lease_token, bufnr, winid)
  end

  M.state.bufnr = bufnr
  M.state.winid = winid
  M.state.job_id = job_id
  M.state.lease_token = lease_token
  M.state.on_exit = opts.on_exit

  -- Set buffer options after termopen (using vim.bo for compatibility)
  -- Don't set buftype - termopen already set it to 'terminal'
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].swapfile = false

  -- Set buffer name
  pcall(vim.api.nvim_buf_set_name, bufnr, "mpwrap://repl")

  -- Setup keymaps for terminal mode
  local key_opts = { buffer = bufnr, noremap = true, silent = true }
  -- Easy exit from terminal mode
  vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", key_opts)

  if config.get().reset_on_repl_start then
    local active_job = M.state.job_id
    -- Give mpremote time to open the port and print its "Connected to
    -- MicroPython at ..." banner before sending Ctrl-D, so the reset
    -- happens once we're truly in live passthrough.
    vim.defer_fn(function()
      if generation == M.state.generation and M.state.job_id == active_job then
        pcall(vim.api.nvim_chan_send, active_job, "\x04")
      end
    end, 500)
  end

  return true
end

-- Stop the REPL
function M.stop(opts)
  opts = opts or {}
  local bufnr = M.state.bufnr
  local winid = M.state.winid
  local job_id = M.state.job_id
  local lease_token = M.state.lease_token

  next_generation() -- stale callbacks from prior process become no-ops
  clear_state_fields()

  if job_id then
    vim.fn.jobstop(job_id)
    -- on_exit normally releases the lease. Keep a bounded fallback in case
    -- an unusual job implementation never delivers that callback.
    if lease_token then
      vim.defer_fn(function()
        jobs.release_device_lease(lease_token)
      end, 2000)
    end
  elseif lease_token then
    jobs.release_device_lease(lease_token)
  end

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    -- Move the window off the terminal buffer before deleting it. If a
    -- buffer being force-deleted is still displayed and Neovim has nothing
    -- else to fall back to in that window (e.g. a sparse session with no
    -- other buffers open), it closes the window instead of just clearing
    -- it - deleting an already-undisplayed buffer can never do that.
    if winid and vim.api.nvim_win_is_valid(winid) then
      local replacement_buf = opts.replacement_buf
      if replacement_buf and vim.api.nvim_buf_is_valid(replacement_buf) then
        vim.api.nvim_win_set_buf(winid, replacement_buf)
      else
        local placeholder = vim.api.nvim_create_buf(false, true)
        vim.bo[placeholder].bufhidden = "wipe"
        vim.api.nvim_win_set_buf(winid, placeholder)
      end
    end

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

-- Send text to REPL
-- @param text string: Text to send
function M.send(text)
  if not M.is_running() then
    vim.notify("REPL is not running", vim.log.levels.WARN)
    return false
  end

  vim.api.nvim_chan_send(M.state.job_id, text .. "\n")
  return true
end

-- Focus the REPL window
function M.focus()
  if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
    vim.api.nvim_set_current_win(M.state.winid)
    vim.cmd("startinsert")
    return true
  end
  return false
end

-- Restart the REPL
function M.restart()
  local winid = M.state.winid
  local on_exit = M.state.on_exit
  M.stop()
  vim.defer_fn(function()
    if winid and vim.api.nvim_win_is_valid(winid) then
      M.create(winid, { on_exit = on_exit })
    end
  end, 100)
end

return M
