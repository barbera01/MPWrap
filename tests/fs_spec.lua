vim.opt.runtimepath:prepend(vim.fn.getcwd())

local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
local assert_equal = helpers.assert_equal
local assert_true = helpers.assert_true
local assert_match = helpers.assert_match

local fs = require("mpwrap.fs")

assert_equal(fs.join_remote_path(":", "main.py"), ":main.py", "join root")
assert_equal(fs.join_remote_path(":lib", "main.py"), ":lib/main.py", "join child")
assert_equal(fs.join_remote_path(":lib/", "main.py"), ":lib/main.py", "join child trailing slash")
assert_equal(fs.parent_remote_path(":lib/drivers"), ":lib", "parent nested")
assert_equal(fs.parent_remote_path(":lib"), ":", "parent root child")
assert_equal(fs.parent_remote_path(":"), ":", "parent root")
assert_equal(fs.remote_basename(":boot.py"), "boot.py", "remote basename root file")
assert_equal(fs.remote_basename(":/lib/boot.py"), "boot.py", "remote basename nested file")

local entries = fs._parse_ls_output("ls :\nboot.py 123\nlib/\nmain.py\n")
assert_equal(#entries, 3, "parse entry count")
assert_equal(entries[1].name, "boot.py", "parse file name")
assert_equal(entries[1].size, 123, "parse file size")
assert_equal(entries[2].type, "dir", "parse directory")
assert_equal(entries[2].name, "lib", "parse directory name")

local size_first_entries = fs._parse_ls_output("ls :\n         139 boot.py\n")
assert_equal(#size_first_entries, 1, "parse size-first entry count")
assert_equal(size_first_entries[1].name, "boot.py", "parse size-first file name")
assert_equal(size_first_entries[1].size, 139, "parse size-first file size")

-- Real mpremote output is always size-first; directories still show a size
-- column (0) rather than omitting it - confirmed against a real device.
local size_first_dir = fs._parse_ls_output("ls :\n           0 sub/\n         781 boot.py\n")
assert_equal(#size_first_dir, 2, "parse size-first dir entry count")
assert_equal(size_first_dir[1].type, "dir", "parse size-first dir type")
assert_equal(size_first_dir[1].name, "sub", "parse size-first dir name")

local ls_prefixed = fs._parse_ls_output("ls :\nls-starts-with-name.py\n")
assert_equal(#ls_prefixed, 1, "retain names that start with ls")
assert_equal(ls_prefixed[1].name, "ls-starts-with-name.py", "retain ls-prefixed file name")

local ls_space_name = fs._parse_ls_output("ls :\n12 ls notes.txt\n")
assert_equal(#ls_space_name, 1, "retain arbitrary names beginning with 'ls '")
assert_equal(ls_space_name[1].name, "ls notes.txt", "retain complete name with leading 'ls '")

local ls_header_nested = fs._parse_ls_output("ls :/lib\nmain.py 10\n")
assert_equal(#ls_header_nested, 1, "skip only actual ls header forms")
assert_equal(ls_header_nested[1].name, "main.py", "header skipped, entry parsed")

local boot_cache = fs.cache_path_for(":boot.py")
local lib_cache = fs.cache_path_for(":lib/boot.py")
assert_true(boot_cache ~= lib_cache, "cache paths should not collide")

local temp_dir = vim.fn.tempname()
vim.fn.mkdir(temp_dir, "p")
local existing = temp_dir .. "/existing.py"
vim.fn.writefile({ "hello" }, existing)

local got_success, got_error
fs.download(":/existing.py", existing, function(success, error)
  got_success = success
  got_error = error
end)
assert_true(got_success == false, "download should refuse overwrite by default")
assert_match(got_error or "", "Local file exists", "download overwrite refusal message")

local original_execute = require("mpwrap.jobs").execute
require("mpwrap.jobs").execute = function(_, cb)
  cb(true, "", "")
end

fs.download(":/existing.py", existing, function(success, error)
  got_success = success
  got_error = error
end, { force = true })
assert_true(got_success == true, "forced download should proceed")
assert_true(got_error == nil, "forced download has no error")
require("mpwrap.jobs").execute = original_execute

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(bufnr, temp_dir .. "/snapshot.py")
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "print('unsaved')" })
vim.bo[bufnr].modified = true

local uploaded_temp_path
local uploaded_payload
local original_upload = fs.upload
fs.upload = function(local_path, _remote_path, callback)
  uploaded_temp_path = local_path
  uploaded_payload = table.concat(vim.fn.readfile(local_path), "\n")
  callback(true)
end

local upload_ok
fs.upload_buffer(bufnr, ":/snapshot.py", function(success)
  upload_ok = success
end)

assert_true(upload_ok == true, "upload_buffer should succeed via snapshot")
assert_match(uploaded_payload or "", "unsaved", "upload must use in-memory buffer content")
assert_true(vim.fn.filereadable(uploaded_temp_path) == 0, "snapshot temp file must be cleaned up")
fs.upload = original_upload

-- Cache fast path must validate target window just like normal open path.
local cache_remote = ":/cache.py"
local cache_path = fs.cache_path_for(cache_remote)
local cache_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(cache_buf, cache_path)
vim.bo[cache_buf].modified = true

local win_to_close = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
local other_win = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(win_to_close)
vim.api.nvim_win_close(win_to_close, true)
vim.api.nvim_set_current_win(other_win)

local open_success
local open_error
fs.open_remote_file(cache_remote, function(success, _local, err)
  open_success = success
  open_error = err
end, { winid = win_to_close })

vim.wait(200, function()
  return open_success ~= nil
end, 10)
assert_true(open_success == false, "cache fast path should fail when target winid is invalid")
assert_match(open_error or "", "no longer valid", "cache fast path should report invalid target window")

local panel_like_win = vim.api.nvim_get_current_win()
local panel_like_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(panel_like_buf, "mpwrap://fake-panel")
vim.api.nvim_win_set_buf(panel_like_win, panel_like_buf)

open_success = nil
open_error = nil
fs.open_remote_file(cache_remote, function(success, _local, err)
  open_success = success
  open_error = err
end, { winid = panel_like_win })

vim.wait(200, function()
  return open_success ~= nil
end, 10)
assert_true(open_success == false, "cache fast path should reject panel-like target windows")
assert_match(
  open_error or "",
  "Refusing to replace mpwrap panel window",
  "cache fast path should reject mpwrap:// target"
)

print("fs_spec passed")
