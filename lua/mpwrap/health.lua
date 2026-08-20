-- :checkhealth provider for mpwrap.nvim
local M = {}

local jobs = require("mpwrap.jobs")
local config = require("mpwrap.config")

-- Neovim >= 0.10 renamed vim.health.report_* to start/ok/warn/error/info.
-- The plugin supports back to 0.8.0, so fall back to the old names.
local health = vim.health
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local err = health.error or health.report_error
local info = health.info or health.report_info

-- Synchronous, device-agnostic mpremote invocation. Bypasses
-- config.get_mpremote_cmd() deliberately: that prepends "connect <device>"
-- for an explicit device config, which would make a plain --version or
-- connect-list check try to open the serial port for no reason.
local function raw_sync(args)
  local result = jobs.execute_sync_raw(args, 3000)
  return result.success, result.stdout or "", result.stderr or ""
end

function M.check()
  start("mpwrap.nvim")

  if vim.fn.has("nvim-0.8.0") == 1 then
    ok("Neovim version >= 0.8.0")
  else
    err("Neovim >= 0.8.0 is required")
  end

  local cfg = config.get()

  if jobs.check_mpremote() then
    ok(string.format("`%s` found on PATH", cfg.mpremote_cmd))

    local version_success, version_stdout, version_stderr = raw_sync({ "--version" })
    if version_success then
      ok("mpremote version: " .. vim.trim(version_stdout))
    else
      warn("Could not run `" .. cfg.mpremote_cmd .. " --version`: " .. vim.trim(version_stderr or ""))
    end

    local list_success, list_stdout, list_stderr = raw_sync({ "connect", "list" })
    if list_success then
      local device_lines = 0
      for line in list_stdout:gmatch("[^\r\n]+") do
        if not line:lower():match("^no devices") then
          device_lines = device_lines + 1
        end
      end
      if device_lines > 0 then
        info(string.format("`mpremote connect list` sees %d device line(s)", device_lines))
      else
        info("No devices found by `mpremote connect list` (fine if none are plugged in)")
      end
    else
      info("Could not run `mpremote connect list` (non-fatal): " .. vim.trim(list_stderr or ""))
    end
  else
    err(string.format("`%s` not found on PATH. Install with: pip install mpremote", cfg.mpremote_cmd))
  end

  local valid, errors = config.validate(cfg)
  if valid then
    ok("Configuration is valid")
  else
    for _, message in ipairs(errors) do
      warn("Config: " .. message)
    end
  end
end

return M
