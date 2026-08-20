vim.opt.runtimepath:prepend(vim.fn.getcwd())

local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
local assert_true = helpers.assert_true
local assert_equal = helpers.assert_equal
local assert_match = helpers.assert_match

local fs = require("mpwrap.fs")
local init = require("mpwrap")
local jobs = require("mpwrap.jobs")

local temp_root = vim.fn.tempname()
vim.fn.mkdir(temp_root, "p")
vim.fn.mkdir(temp_root .. "/pkg", "p")
vim.fn.mkdir(temp_root .. "/dir_conflict", "p")
vim.fn.mkdir(temp_root .. "/node_modules", "p")
vim.fn.writefile({ "print('main')" }, temp_root .. "/main.py")
vim.fn.writefile({ "print('mod')" }, temp_root .. "/pkg/mod.py")
vim.fn.writefile({ "local file" }, temp_root .. "/file_conflict")
vim.fn.writefile({ "ignore" }, temp_root .. "/node_modules/skip.js")
vim.fn.writefile({ "swap" }, temp_root .. "/tmp.swp")

local original_list = fs.list
local remote_map = {
  [":"] = {
    { name = "pkg", type = "dir" },
    { name = "main.py", type = "file" },
    { name = "old.py", type = "file" },
    { name = "dir_conflict", type = "file" },
    { name = "file_conflict", type = "dir" },
  },
  [":/pkg"] = {
    { name = "obsolete.py", type = "file" },
    { name = "mod.py", type = "file" },
  },
  [":pkg"] = {
    { name = "obsolete.py", type = "file" },
    { name = "mod.py", type = "file" },
  },
  [":/file_conflict"] = {
    { name = "nested.txt", type = "file" },
    { name = "subdir", type = "dir" },
  },
  [":file_conflict"] = {
    { name = "nested.txt", type = "file" },
    { name = "subdir", type = "dir" },
  },
  [":/file_conflict/subdir"] = {
    { name = "deep.txt", type = "file" },
  },
  [":file_conflict/subdir"] = {
    { name = "deep.txt", type = "file" },
  },
}

fs.list = function(path, cb)
  cb(true, remote_map[path] or {}, nil)
end

local planned
fs.plan_directory_sync(temp_root, ":", {
  ignore_patterns = { "node_modules", "*.swp" },
}, function(success, plan, err)
  assert_true(success, "plan_directory_sync should succeed: " .. tostring(err))
  planned = plan
end)

vim.wait(200, function()
  return planned ~= nil
end, 10)

assert_true(planned ~= nil, "plan should be produced")
assert_equal(planned.remote_root, ":", "plan remote root must be ':'")
assert_true(planned.summary.type_conflicts >= 2, "plan should include type conflicts")

local conflict_in_delete_files = false
local conflict_in_delete_dirs = false
for _, item in ipairs(planned.delete_files or {}) do
  if item.rel_path == "dir_conflict" then
    conflict_in_delete_files = true
  end
end
for _, item in ipairs(planned.delete_dirs or {}) do
  if item.rel_path == "file_conflict" then
    conflict_in_delete_dirs = true
  end
end
assert_true(conflict_in_delete_files == false, "conflict paths should not be duplicated into ordinary delete lists")
assert_true(conflict_in_delete_dirs == false, "conflict root dirs should not be duplicated into ordinary delete lists")

local operations = {}
local deleted = {}
local existing_dirs = {
  [":/pkg"] = true,
  [":/file_conflict"] = true,
  [":/file_conflict/subdir"] = true,
}
local existing_files = {
  [":/old.py"] = true,
  [":/dir_conflict"] = true,
  [":/pkg/obsolete.py"] = true,
  [":/file_conflict/nested.txt"] = true,
  [":/file_conflict/subdir/deep.txt"] = true,
}

local original_mkdir = fs.mkdir
local original_upload = fs.upload
local original_delete = fs.delete
local original_execute = jobs.execute

local function mark_deleted(remote)
  if deleted[remote] then
    return false
  end
  deleted[remote] = true
  existing_files[remote] = nil
  existing_dirs[remote] = nil
  return true
end

fs.mkdir = function(remote, cb)
  table.insert(operations, "mkdir " .. remote)
  existing_dirs[remote] = true
  cb(true)
end

fs.upload = function(_local, remote, cb)
  table.insert(operations, "upload " .. remote)
  existing_files[remote] = true
  cb(true)
end

fs.delete = function(remote, cb)
  table.insert(operations, "delete-file " .. remote)
  if not existing_files[remote] then
    cb(false, "duplicate/missing file delete: " .. remote)
    return
  end
  if not mark_deleted(remote) then
    cb(false, "duplicate file delete: " .. remote)
    return
  end
  cb(true)
end

jobs.execute = function(args, cb)
  table.insert(operations, "exec " .. table.concat(args, " "))
  if args[1] == "fs" and args[2] == "rmdir" then
    local target = args[3]
    for file_path, _ in pairs(existing_files) do
      if file_path:sub(1, #target + 1) == target .. "/" then
        cb(false, "directory not empty: " .. target)
        return
      end
    end
    for dir_path, _ in pairs(existing_dirs) do
      if dir_path ~= target and dir_path:sub(1, #target + 1) == target .. "/" then
        cb(false, "directory not empty: " .. target)
        return
      end
    end
    if not existing_dirs[target] then
      cb(false, "duplicate/missing rmdir: " .. target)
      return
    end
    if not mark_deleted(target) then
      cb(false, "duplicate rmdir: " .. target)
      return
    end
    cb(true, "", "")
    return
  end
  cb(true, "", "")
end

local applied_ok, applied_err
fs.apply_directory_sync(planned, function(ok, err)
  applied_ok = ok
  applied_err = err
end, function() end)

vim.wait(300, function()
  return applied_ok ~= nil
end, 10)
assert_true(applied_ok == true, "apply_directory_sync should succeed: " .. tostring(applied_err))

local function op_index(prefix)
  for i, op in ipairs(operations) do
    if op == prefix then
      return i
    end
  end
  return nil
end

local idx_delete_conflict_file = op_index("delete-file :/dir_conflict")
local idx_mkdir_conflict_dir = op_index("mkdir :/dir_conflict")
assert_true(idx_delete_conflict_file ~= nil and idx_mkdir_conflict_dir ~= nil, "dir-vs-file conflict ops should exist")
assert_true(idx_delete_conflict_file < idx_mkdir_conflict_dir, "conflicting remote file must be deleted before mkdir")

local idx_delete_nested = op_index("delete-file :/file_conflict/nested.txt")
local idx_delete_deep = op_index("delete-file :/file_conflict/subdir/deep.txt")
local idx_rmdir_subdir = op_index("exec fs rmdir :/file_conflict/subdir")
local idx_rmdir_root = op_index("exec fs rmdir :/file_conflict")
local idx_upload_conflict_file = op_index("upload :/file_conflict")

assert_true(
  idx_delete_nested and idx_delete_deep and idx_rmdir_subdir and idx_rmdir_root and idx_upload_conflict_file,
  "file-vs-dir conflict sequence should include nested deletes/rmdirs/upload"
)
assert_true(idx_delete_deep < idx_rmdir_subdir, "deep descendant file must be deleted before descendant rmdir")
assert_true(idx_rmdir_subdir < idx_rmdir_root, "descendant directory must be removed before root conflict rmdir")
assert_true(idx_rmdir_root < idx_upload_conflict_file, "conflict root dir must be removed before uploading file")

local idx_upload_main = op_index("upload :/main.py")
local idx_delete_old = op_index("delete-file :/old.py")
assert_true(
  idx_upload_main and idx_delete_old and idx_upload_main < idx_delete_old,
  "ordinary remote-only deletions must occur after upload phase"
)

local second_ok, second_err
fs.apply_directory_sync(planned, function(ok, err)
  second_ok = ok
  second_err = err
end, function() end)
assert_true(second_ok == false, "applied plan should be one-shot")
assert_match(second_err or "", "already applied/consumed", "one-shot message after success")

local fail_plan = {
  kind = "directory_sync_plan",
  id = 9999,
  local_root = temp_root,
  remote_root = ":",
  create_dirs = { { rel_path = "a", remote_path = ":/a" } },
  upload_files = { { rel_path = "a/b.py", local_path = temp_root .. "/main.py", remote_path = ":/a/b.py" } },
  delete_files = { { rel_path = "old.py", remote_path = ":/old.py" } },
  delete_dirs = { { rel_path = "old", remote_path = ":/old" } },
  type_conflicts = {},
  ignored = {},
  skipped_symlinks = {},
  summary = {},
  applied = false,
}

operations = {}
fs.mkdir = function(remote, cb)
  table.insert(operations, "mkdir " .. remote)
  cb(true)
end
fs.upload = function(_local, remote, cb)
  table.insert(operations, "upload " .. remote)
  cb(false, "mock upload failure")
end
fs.delete = function(remote, cb)
  table.insert(operations, "delete-file " .. remote)
  cb(true)
end
jobs.execute = function(args, cb)
  table.insert(operations, "exec " .. table.concat(args, " "))
  cb(true, "", "")
end

local fail_ok, fail_err
fs.apply_directory_sync(fail_plan, function(ok, err)
  fail_ok = ok
  fail_err = err
end, function() end)

vim.wait(200, function()
  return fail_ok ~= nil
end, 10)
assert_true(fail_ok == false, "apply should fail on upload error")
assert_match(fail_err or "", "Partial sync failure", "partial failure message")

local retry_ok, retry_err
fs.apply_directory_sync(fail_plan, function(ok, err)
  retry_ok = ok
  retry_err = err
end, function() end)
assert_true(retry_ok == false, "failed plan should also be consumed")
assert_match(retry_err or "", "already applied/consumed", "one-shot message after failure")

-- Mutated unsafe plan should be rejected before any operation.
local unsafe_plan = {
  kind = "directory_sync_plan",
  id = 10001,
  local_root = temp_root,
  remote_root = ":",
  create_dirs = {},
  upload_files = {
    {
      rel_path = "safe.py",
      local_path = "/etc/hosts",
      remote_path = ":/safe.py",
    },
  },
  delete_files = {},
  delete_dirs = {},
  type_conflicts = {},
  ignored = {},
  skipped_symlinks = {},
  summary = {},
  applied = false,
}

local touched_ops = 0
fs.mkdir = function(_, cb)
  touched_ops = touched_ops + 1
  cb(true)
end
fs.upload = function(_, _, cb)
  touched_ops = touched_ops + 1
  cb(true)
end
fs.delete = function(_, cb)
  touched_ops = touched_ops + 1
  cb(true)
end
jobs.execute = function(_, cb)
  touched_ops = touched_ops + 1
  cb(true, "", "")
end

local unsafe_ok, unsafe_err
fs.apply_directory_sync(unsafe_plan, function(ok, err)
  unsafe_ok = ok
  unsafe_err = err
end, function() end)
assert_true(unsafe_ok == false, "unsafe mutated plan must be rejected")
assert_true(touched_ops == 0, "unsafe plan must perform zero operations")
assert_match(unsafe_err or "", "local_path", "unsafe plan error should mention local path validation")

fs.list = original_list
fs.mkdir = original_mkdir
fs.upload = original_upload
fs.delete = original_delete
jobs.execute = original_execute

-- Cancellation path for MpWrapSyncDir should not apply.
local original_plan = fs.plan_directory_sync
local original_apply = fs.apply_directory_sync
local original_confirm = vim.fn.confirm

local apply_called = false
fs.plan_directory_sync = function(_local, _root, _opts, cb)
  cb(true, {
    kind = "directory_sync_plan",
    id = 777,
    local_root = temp_root,
    remote_root = ":",
    create_dirs = {},
    upload_files = {},
    delete_files = { { rel_path = "old.py", remote_path = ":/old.py" } },
    delete_dirs = {},
    type_conflicts = {},
    ignored = {},
    skipped_symlinks = {},
    summary = {
      create_dirs = 0,
      upload_files = 0,
      delete_files = 1,
      delete_dirs = 0,
      type_conflicts = 0,
      ignored = 0,
      skipped_symlinks = 0,
    },
    applied = false,
  })
end
fs.apply_directory_sync = function()
  apply_called = true
end
vim.fn.confirm = function()
  return 2 -- No
end

init.setup({ device = "auto" })
vim.cmd("MpWrapSyncDir " .. vim.fn.fnameescape(temp_root))
assert_true(apply_called == false, "MpWrapSyncDir cancellation should not apply plan")

fs.plan_directory_sync = original_plan
fs.apply_directory_sync = original_apply
vim.fn.confirm = original_confirm

print("sync_spec passed")
