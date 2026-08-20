vim.opt.runtimepath:prepend(vim.fn.getcwd())

local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
local assert_true = helpers.assert_true
local assert_equal = helpers.assert_equal

local mpremote = require("mpwrap")
local fs = mpremote.fs

local ok1, err1 = pcall(function()
  mpremote.setup({ device = "auto" })
end)
assert_true(ok1, "first setup should succeed: " .. tostring(err1))

local ok2, err2 = pcall(function()
  mpremote.setup({ device = "auto", panel_width = 60 })
end)
assert_true(ok2, "repeated setup should be idempotent: " .. tostring(err2))

mpremote.config.select_device_port("/dev/ttyFAKE")
assert_equal(mpremote.config.get_selected_device(), "/dev/ttyFAKE", "test precondition: selected port set")
mpremote.setup({ device = "auto" })
assert_equal(mpremote.config.get_selected_device(), nil, "setup() should clear stale runtime selected port")

assert_true(vim.fn.exists(":MpWrapToggle") == 2, "MpWrapToggle command should exist after setup")
assert_true(vim.fn.exists(":MpWrapDownload") == 2, "MpWrapDownload command should exist after setup")
assert_true(vim.fn.exists(":MpWrapSyncBuffer") == 2, "MpWrapSyncBuffer command should exist after setup")
assert_true(vim.fn.exists(":MpWrapSyncDir") == 2, "MpWrapSyncDir command should exist after setup")

local ok3 = pcall(function()
  mpremote.setup({ panel_width = 1 })
end)
assert_true(not ok3, "invalid setup must raise a Lua error")

local original_upload_current = fs.upload_current_buffer
local called_alias = false
fs.upload_current_buffer = function(_remote, cb)
  called_alias = true
  cb(true)
end
vim.cmd("MpWrapUpload :/alias.py")
assert_true(called_alias, "MpWrapUpload alias should invoke sync-buffer implementation")
fs.upload_current_buffer = original_upload_current

print("init_spec passed")
