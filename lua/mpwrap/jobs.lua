-- Async job execution for mpremote commands
local M = {}
local config = require("mpwrap.config")

-- Count of in-flight mpremote subprocesses (execute/execute_raw). mpremote
-- holds the serial port exclusively, so two of these racing (e.g. a user
-- firing a second panel action before the first's callback chain finishes)
-- silently corrupts or half-completes one of them. is_busy() lets callers
-- refuse to start a new one instead.
local active_jobs = 0
local lease_seq = 0
local device_lease = nil

local function next_token()
  lease_seq = lease_seq + 1
  return lease_seq
end

local function lease_error(owner)
  if not device_lease then
    return "Device is not leased"
  end
  local who = owner and owner.label or "job"
  return string.format("Serial port is busy (owned by %s, requested by %s)", device_lease.label, who)
end

-- Acquire serial-device exclusivity.
-- Returns token on success, nil,error on failure.
function M.acquire_device_lease(owner)
  owner = owner or {}
  if device_lease then
    return nil, lease_error(owner)
  end

  local token = next_token()
  device_lease = {
    token = token,
    label = owner.label or "job",
  }
  return token, nil
end

function M.release_device_lease(token)
  if not device_lease then
    return false
  end
  if device_lease.token ~= token then
    return false
  end
  device_lease = nil
  return true
end

function M.current_device_lease()
  return device_lease
end

-- @return boolean: true if an mpremote subprocess is currently running
function M.is_busy()
  return active_jobs > 0 or device_lease ~= nil
end

-- Execute mpremote command asynchronously
-- @param args table: Command arguments to pass to mpremote
-- @param callback function: Called with (success, output) when complete
-- @param on_stderr function: Optional callback for stderr output
function M.execute(args, callback, on_stderr)
  local lease_token, lease_err = M.acquire_device_lease({ label = "device job" })
  if not lease_token then
    if callback then
      vim.schedule(function()
        callback(false, "", lease_err)
      end)
    end
    return -1
  end

  local cmd = config.get_mpremote_cmd(args)
  local stdout_lines = {}
  local stderr_lines = {}

  active_jobs = active_jobs + 1

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,

    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout_lines, line)
          end
        end
      end
    end,

    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_lines, line)
            if on_stderr then
              on_stderr(line)
            end
          end
        end
      end
    end,

    on_exit = function(_, exit_code)
      M.release_device_lease(lease_token)
      active_jobs = active_jobs - 1
      local success = exit_code == 0
      local output = table.concat(stdout_lines, "\n")
      local errors = table.concat(stderr_lines, "\n")

      if callback then
        vim.schedule(function()
          callback(success, output, errors)
        end)
      end
    end,
  })

  if job_id <= 0 then
    M.release_device_lease(lease_token)
    active_jobs = active_jobs - 1
    if callback then
      vim.schedule(function()
        callback(false, "", "Failed to start job")
      end)
    end
  end

  return job_id
end

-- Execute raw mpremote command arguments without adding configured device
-- selection. Useful for commands like `connect list`.
function M.execute_raw(args, callback, on_stderr, opts)
  opts = opts or {}
  local requires_device = opts.requires_device == true
  local lease_token
  if requires_device then
    local lease_err
    lease_token, lease_err = M.acquire_device_lease({ label = opts.lease_label or "device raw job" })
    if not lease_token then
      if callback then
        vim.schedule(function()
          callback(false, "", lease_err)
        end)
      end
      return -1
    end
  end

  local cfg = config.get()
  local cmd = { cfg.mpremote_cmd }
  for _, arg in ipairs(args or {}) do
    table.insert(cmd, arg)
  end

  local stdout_lines = {}
  local stderr_lines = {}

  active_jobs = active_jobs + 1

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout_lines, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_lines, line)
            if on_stderr then
              on_stderr(line)
            end
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      if lease_token then
        M.release_device_lease(lease_token)
      end
      active_jobs = active_jobs - 1
      if callback then
        vim.schedule(function()
          callback(exit_code == 0, table.concat(stdout_lines, "\n"), table.concat(stderr_lines, "\n"))
        end)
      end
    end,
  })

  if job_id <= 0 then
    if lease_token then
      M.release_device_lease(lease_token)
    end
    active_jobs = active_jobs - 1
    if callback then
      vim.schedule(function()
        callback(false, "", "Failed to start job")
      end)
    end
  end

  return job_id
end

-- Execute mpremote command synchronously (blocking)
-- Use sparingly, prefer async execution
function M.execute_sync(args, timeout)
  local cmd = config.get_mpremote_cmd(args)
  timeout = timeout or 5000 -- 5 second default timeout

  local lease_token, lease_err = M.acquire_device_lease({ label = "sync device job" })
  if not lease_token then
    return {
      success = false,
      stdout = "",
      stderr = lease_err,
      code = -1,
    }
  end

  if vim.system then
    local result = vim.system(cmd, { timeout = timeout }):wait()
    M.release_device_lease(lease_token)
    return {
      success = result.code == 0,
      stdout = result.stdout or "",
      stderr = result.stderr or "",
      code = result.code,
    }
  end

  local stdout_lines = {}
  local stderr_lines = {}
  local finished = false
  local code = -1

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout_lines, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      code = exit_code
      finished = true
    end,
  })

  if job_id <= 0 then
    M.release_device_lease(lease_token)
    return {
      success = false,
      stdout = "",
      stderr = "Failed to start job",
      code = -1,
    }
  end

  local wait_result = vim.fn.jobwait({ job_id }, timeout)[1]
  if wait_result == -1 and not finished then
    vim.fn.jobstop(job_id)
    M.release_device_lease(lease_token)
    return {
      success = false,
      stdout = table.concat(stdout_lines, "\n"),
      stderr = "Timed out after " .. timeout .. "ms",
      code = -1,
    }
  end

  M.release_device_lease(lease_token)

  return {
    success = code == 0,
    stdout = table.concat(stdout_lines, "\n"),
    stderr = table.concat(stderr_lines, "\n"),
    code = code,
  }
end

function M.execute_sync_raw(args, timeout)
  local cfg = config.get()
  local cmd = { cfg.mpremote_cmd }
  for _, arg in ipairs(args or {}) do
    table.insert(cmd, arg)
  end

  timeout = timeout or 5000

  if vim.system then
    local result = vim.system(cmd, { timeout = timeout }):wait()
    return {
      success = result.code == 0,
      stdout = result.stdout or "",
      stderr = result.stderr or "",
      code = result.code,
    }
  end

  local stdout_lines = {}
  local stderr_lines = {}
  local code = -1

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout_lines, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      code = exit_code
    end,
  })

  if job_id <= 0 then
    return {
      success = false,
      stdout = "",
      stderr = "Failed to start job",
      code = -1,
    }
  end

  local wait_result = vim.fn.jobwait({ job_id }, timeout)[1]
  if wait_result == -1 then
    vim.fn.jobstop(job_id)
    return {
      success = false,
      stdout = table.concat(stdout_lines, "\n"),
      stderr = "Timed out after " .. timeout .. "ms",
      code = -1,
    }
  end

  return {
    success = code == 0,
    stdout = table.concat(stdout_lines, "\n"),
    stderr = table.concat(stderr_lines, "\n"),
    code = code,
  }
end

-- Check if mpremote is available in PATH
function M.check_mpremote()
  local cfg = config.get()
  local result = vim.fn.executable(cfg.mpremote_cmd)
  return result == 1
end

-- Get mpremote version. Uses execute_raw (not execute) since --version
-- doesn't touch a device - going through the configured device would
-- prepend "connect <device>", making a plain version check try to open the
-- serial port for no reason.
function M.get_version(callback)
  M.execute_raw({ "--version" }, function(success, output)
    if callback then
      callback(success, output)
    end
  end)
end

return M
