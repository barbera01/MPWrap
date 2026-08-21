-- Configuration management for mpwrap.nvim
local M = {}

-- Default configuration
M.defaults = {
  -- Command to invoke mpremote
  mpremote_cmd = "mpremote",

  -- Device selection: "auto", "pick", or explicit port like "/dev/ttyUSB0"
  device = "auto",
  pick_device_on_open = true,

  -- Panel layout
  panel_width = 50,
  panel_position = "right", -- "left" or "right"
  repl_height_ratio = 0.4, -- REPL takes 40% of panel height
  auto_start_repl = false,

  -- Soft-reset the board right after attaching the REPL (sends Ctrl-D over
  -- the pty once connected). `mpremote repl` alone does NOT reset the
  -- device (mpremote only auto-resets for mount/eval/exec/run/fs), so
  -- without this any boot.py/main.py output that already happened before
  -- the panel opened is lost, and only output printed after attaching
  -- shows up. Clears the Python heap/globals on every REPL (re)start; set
  -- to false to preserve REPL state instead.
  reset_on_repl_start = true,

  -- Enable default keymaps
  keymaps = true,

  -- Exact-mirror directory sync ignore patterns (glob-like)
  sync_ignore = {
    ".git",
    ".hg",
    ".svn",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    "node_modules",
    "dist",
    "build",
    ".DS_Store",
    "*.swp",
    "*.swo",
    "*~",
  },
  sync_ignore_extra = {},

  -- Default keybindings (buffer-local in panel panes)
  keys = {
    next_section = "<Tab>",
    previous_section = "<S-Tab>",
    refresh = "r",
    upload = "u",
    download = "D",
    move = "M",
    delete = "dd",
    clear_all = "C",
    sync_dir = "S",
    restart_device = "x",
    action_menu = "a",
    start_repl = "R",
    stop_repl = "s",
    open = "<CR>",
    close_panel = "q",
    mkdir = "m",
    parent = "-",
  },
}

-- Current active configuration
M.options = {}
M.runtime = {
  selected_device = nil,
}

-- Known top-level and keys.* option names/types, used by validate() to catch
-- typos and wrong types at setup() time instead of failing later inside a
-- keymap callback with a confusing error.
local KNOWN_OPTIONS = {
  mpremote_cmd = "string",
  device = "string",
  pick_device_on_open = "boolean",
  panel_width = "number",
  panel_position = "string",
  repl_height_ratio = "number",
  auto_start_repl = "boolean",
  reset_on_repl_start = "boolean",
  keymaps = "boolean",
  keys = "table",
  sync_ignore = "table",
  sync_ignore_extra = "table",
}

local KNOWN_KEY_BINDINGS = {
  next_section = "string",
  previous_section = "string",
  refresh = "string",
  upload = "string",
  download = "string",
  move = "string",
  delete = "string",
  clear_all = "string",
  sync_dir = "string",
  restart_device = "string",
  action_menu = "string",
  start_repl = "string",
  stop_repl = "string",
  open = "string",
  close_panel = "string",
  mkdir = "string",
  parent = "string",
}

local function is_dense_string_list(value)
  if type(value) ~= "table" then
    return false, "must be a list"
  end

  local max_index = 0
  local count = 0
  for key, entry in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false, "must be a dense array-style list"
    end
    if type(entry) ~= "string" or vim.trim(entry) == "" then
      return false, "entries must be non-empty strings"
    end
    if key > max_index then
      max_index = key
    end
    count = count + 1
  end

  if max_index ~= count then
    return false, "must not be sparse"
  end

  return true
end

-- Validate a (possibly partial) options table against the known option set.
-- Works for both raw setup() opts and a fully-merged config, since it only
-- checks keys that are actually present.
-- @return boolean valid, string[] errors
function M.validate(opts)
  opts = opts or {}
  local errors = {}

  local keys_to_check = opts.keys
  if keys_to_check == nil and M.defaults.keys then
    keys_to_check = M.defaults.keys
  end

  for key, value in pairs(opts) do
    local expected_type = KNOWN_OPTIONS[key]
    if not expected_type then
      table.insert(errors, string.format("unknown option %q", key))
    elseif type(value) ~= expected_type then
      table.insert(errors, string.format("option %q should be a %s, got %s", key, expected_type, type(value)))
    end
  end

  if type(opts.keys) == "table" then
    for key, value in pairs(opts.keys) do
      local expected_type = KNOWN_KEY_BINDINGS[key]
      if not expected_type then
        table.insert(errors, string.format("unknown keys.%s", key))
      elseif type(value) ~= expected_type then
        table.insert(errors, string.format("keys.%s should be a %s, got %s", key, expected_type, type(value)))
      end
    end
  end

  if opts.panel_position and opts.panel_position ~= "left" and opts.panel_position ~= "right" then
    table.insert(errors, 'panel_position must be "left" or "right"')
  end

  if type(opts.mpremote_cmd) == "string" then
    if vim.trim(opts.mpremote_cmd) == "" then
      table.insert(errors, "mpremote_cmd must be a non-empty string")
    end
  end

  if type(opts.device) == "string" then
    local device = vim.trim(opts.device)
    if device == "" then
      table.insert(errors, "device must be a non-empty string")
    end
  end

  if opts.panel_width ~= nil and type(opts.panel_width) == "number" then
    if opts.panel_width % 1 ~= 0 then
      table.insert(errors, "panel_width must be an integer")
    elseif opts.panel_width < 20 then
      table.insert(errors, "panel_width must be at least 20 columns")
    end
  end

  if type(opts.repl_height_ratio) == "number" and (opts.repl_height_ratio <= 0 or opts.repl_height_ratio >= 1) then
    table.insert(errors, "repl_height_ratio must be > 0 and < 1")
  end

  if type(keys_to_check) == "table" then
    local seen = {}
    for key, value in pairs(keys_to_check) do
      if type(value) == "string" then
        if vim.trim(value) == "" then
          table.insert(errors, string.format("keys.%s must be a non-empty string", key))
        end
        if seen[value] then
          table.insert(
            errors,
            string.format("key mapping collision: keys.%s and keys.%s are both %q", seen[value], key, value)
          )
        else
          seen[value] = key
        end
      end
    end
  end

  local function validate_ignore_table(name, value)
    if value ~= nil then
      local ok, reason = is_dense_string_list(value)
      if not ok then
        table.insert(errors, string.format("%s %s", name, reason))
      end
    end
  end

  validate_ignore_table("sync_ignore", opts.sync_ignore)
  validate_ignore_table("sync_ignore_extra", opts.sync_ignore_extra)

  return #errors == 0, errors
end

-- Setup function to merge user config with defaults
function M.setup(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  if opts.sync_ignore ~= nil then
    merged.sync_ignore = vim.deepcopy(opts.sync_ignore)
  end
  if opts.sync_ignore_extra ~= nil then
    merged.sync_ignore_extra = vim.deepcopy(opts.sync_ignore_extra)
  end
  local valid, errors = M.validate(merged)
  if not valid then
    error("mpwrap.nvim config error:\n- " .. table.concat(errors, "\n- "), 2)
  end

  M.options = merged
  -- Fresh setup() call should never inherit a stale runtime selection.
  M.runtime.selected_device = nil
  return M.options
end

-- Get current configuration
function M.get()
  if vim.tbl_isempty(M.options) then
    M.options = vim.deepcopy(M.defaults)
  end
  return M.options
end

function M.get_device_policy()
  return M.get().device
end

function M.set_device_policy(policy)
  if type(policy) ~= "string" or vim.trim(policy) == "" then
    error("mpwrap.nvim: device policy must be a non-empty string", 2)
  end
  M.get().device = policy
  if policy ~= "auto" and policy ~= "pick" then
    M.runtime.selected_device = nil
  end
end

function M.select_device_port(port)
  if type(port) ~= "string" or vim.trim(port) == "" then
    error("mpwrap.nvim: selected device port must be a non-empty string", 2)
  end
  M.runtime.selected_device = port
end

function M.clear_selected_device()
  M.runtime.selected_device = nil
end

function M.get_selected_device()
  return M.runtime.selected_device
end

function M.get_effective_device()
  local policy = M.get().device
  if policy == "auto" or policy == "pick" then
    return M.runtime.selected_device
  end
  return policy
end

function M.get_sync_ignore_patterns()
  local cfg = M.get()
  local patterns = {}
  for _, p in ipairs(cfg.sync_ignore or {}) do
    table.insert(patterns, p)
  end
  for _, p in ipairs(cfg.sync_ignore_extra or {}) do
    table.insert(patterns, p)
  end
  return patterns
end

-- Build mpremote command with device selection
function M.get_mpremote_cmd(args)
  local cfg = M.get()
  local cmd = { cfg.mpremote_cmd }

  -- Add device selection when one is concretely known
  local effective_device = M.get_effective_device()
  if effective_device and effective_device ~= "" then
    table.insert(cmd, "connect")
    table.insert(cmd, effective_device)
  end

  -- Add the actual command arguments
  if args then
    for _, arg in ipairs(args) do
      table.insert(cmd, arg)
    end
  end

  return cmd
end

return M
