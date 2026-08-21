vim.opt.runtimepath:prepend(vim.fn.getcwd())

local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local assert_match = helpers.assert_match

local config = require("mpwrap.config")

config.options = {}
config.runtime = { selected_device = nil }

config.setup({ device = "/dev/ttyUSB0", panel_width = 72 })
local cmd = config.get_mpremote_cmd({ "fs", "ls", ":" })
assert_equal(table.concat(cmd, " "), "mpremote connect /dev/ttyUSB0 fs ls :", "explicit device command")
assert_equal(config.get().panel_width, 72, "config override")
assert_equal(config.get().keys.next_section, "<Tab>", "default next-section mapping")
assert_equal(config.get().keys.previous_section, "<S-Tab>", "default previous-section mapping")

config.setup({ device = "auto" })
cmd = config.get_mpremote_cmd({ "repl" })
assert_equal(table.concat(cmd, " "), "mpremote repl", "auto device command")

-- validate() - valid config
local valid, errors = config.validate({ panel_width = 60, device = "auto", keys = { refresh = "r" } })
assert_true(valid, "valid config should pass")
assert_equal(#errors, 0, "valid config has no errors")

-- validate() - unknown top-level key (typo)
valid, errors = config.validate({ pnael_width = 60 })
assert_true(not valid, "typo'd top-level key should fail")
assert_true(errors[1]:match("unknown option") ~= nil, "reports unknown option")

-- validate() - wrong type
valid, errors = config.validate({ panel_width = "fifty" })
assert_true(not valid, "wrong type should fail")
assert_true(errors[1]:match("should be a number") ~= nil, "reports expected type")

valid, errors = config.validate({ mpremote_cmd = 42, device = false })
assert_true(not valid, "wrong string option types should fail without throwing")
assert_true(#errors == 2, "both wrong string option types should be reported")

-- validate() - unknown keys.* sub-key
valid, errors = config.validate({ keys = { refrsh = "r" } })
assert_true(not valid, "typo'd keys sub-key should fail")
assert_true(errors[1]:match("unknown keys%.") ~= nil, "reports unknown keys.* sub-key")

-- validate() - bad panel_position enum
valid, errors = config.validate({ panel_position = "top" })
assert_true(not valid, "invalid panel_position should fail")
assert_true(errors[1]:match("panel_position") ~= nil, "reports panel_position error")

-- validate() - empty/nil opts is valid (nothing to check)
local nil_opts_valid = config.validate(nil)
assert_true(nil_opts_valid, "nil opts should be valid")

valid, errors = config.validate({ panel_width = 10 })
assert_true(not valid, "tiny panel_width should fail")
assert_match(errors[1], "panel_width", "panel_width error message")

valid, errors = config.validate({ repl_height_ratio = 1 })
assert_true(not valid, "repl_height_ratio=1 should fail")
assert_match(table.concat(errors, "\n"), "repl_height_ratio", "repl_height_ratio validation message")

valid, errors = config.validate({ mpremote_cmd = "" })
assert_true(not valid, "empty mpremote_cmd should fail")
assert_match(table.concat(errors, "\n"), "mpremote_cmd", "mpremote_cmd validation message")

valid, errors = config.validate({ keys = { refresh = "", upload = "u" } })
assert_true(not valid, "empty key mapping should fail")
assert_match(table.concat(errors, "\n"), "non%-empty", "empty key validation message")

valid, errors = config.validate({ keys = { refresh = "x", upload = "x" } })
assert_true(not valid, "mapping collisions should fail")
assert_match(table.concat(errors, "\n"), "collision", "mapping collision validation message")

valid, errors = config.validate({ sync_ignore = { ".git", "" } })
assert_true(not valid, "empty sync_ignore entries should fail")
assert_match(table.concat(errors, "\n"), "sync_ignore", "sync_ignore validation message")

valid, errors = config.validate({ sync_ignore = { [1] = ".git", [3] = "dist" } })
assert_true(not valid, "sparse sync_ignore list should fail")
assert_match(table.concat(errors, "\n"), "sparse", "sparse sync_ignore validation message")

valid, errors = config.validate({ sync_ignore = { include = ".git" } })
assert_true(not valid, "keyed sync_ignore table should fail")
assert_match(table.concat(errors, "\n"), "dense", "keyed sync_ignore validation message")

local ok, err = pcall(function()
  config.setup({ panel_width = 1 })
end)
assert_true(not ok, "invalid setup must error")
assert_match(err, "config error", "invalid setup error text")

local before = vim.deepcopy(config.get())
ok = pcall(function()
  config.setup({ panel_width = 1 })
end)
assert_true(not ok, "invalid setup still errors")
local after = config.get()
assert_equal(after.panel_width, before.panel_width, "invalid config must not merge into active options")

config.setup({ device = "auto" })
config.select_device_port("/dev/ttyUSB5")
assert_equal(config.get_effective_device(), "/dev/ttyUSB5", "effective device comes from runtime selection")
config.clear_selected_device()
assert_equal(config.get_effective_device(), nil, "cleared selected device")

config.set_device_policy("/dev/ttyS1")
assert_equal(config.get_effective_device(), "/dev/ttyS1", "explicit policy used as effective device")

config.setup({ sync_ignore = { "dist" } })
local patterns = config.get_sync_ignore_patterns()
assert_equal(patterns[1], "dist", "sync_ignore should replace defaults when provided")
assert_equal(#patterns, 1, "sync_ignore replacement should be exact")

config.setup({ sync_ignore = { "dist" }, sync_ignore_extra = { "*.tmp" } })
patterns = config.get_sync_ignore_patterns()
assert_equal(#patterns, 2, "sync_ignore_extra should extend active base ignore list")
assert_equal(patterns[1], "dist", "active base should remain first")
assert_equal(patterns[2], "*.tmp", "sync_ignore_extra appended")

print("config_spec passed")
