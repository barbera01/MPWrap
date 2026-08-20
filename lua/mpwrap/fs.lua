-- Filesystem operations for MicroPython device
local M = {}
local jobs = require("mpwrap.jobs")
local plan_seq = 0

local function normalize_force(opts_or_force)
  if type(opts_or_force) == "table" then
    return opts_or_force.force == true
  end
  return opts_or_force == true
end

local function is_ls_header_line(trimmed)
  -- mpremote header forms: "ls :", "ls :/", "ls :/path"
  return trimmed:match("^ls%s+:%S*$") ~= nil
end

local function validate_target_window(winid)
  if not winid then
    return true
  end

  if not vim.api.nvim_win_is_valid(winid) then
    return false, "Target window is no longer valid"
  end

  local current_buf = vim.api.nvim_win_get_buf(winid)
  local current_name = vim.api.nvim_buf_get_name(current_buf)
  if current_name:match("^mpwrap://") then
    return false, "Refusing to replace mpwrap panel window"
  end

  return true
end

local function split_path(path)
  local out = {}
  for part in tostring(path or ""):gmatch("[^/]+") do
    table.insert(out, part)
  end
  return out
end

local function path_depth(path)
  local depth = 0
  for _ in tostring(path or ""):gmatch("[^/]+") do
    depth = depth + 1
  end
  return depth
end

local function normalize_remote_root(remote_root)
  if remote_root == nil or remote_root == "" or remote_root == ":" or remote_root == ":/" then
    return ":"
  end
  return nil
end

local function rel_is_safe(rel)
  if rel == "" then
    return true
  end
  if rel:sub(1, 1) == "/" or rel:sub(1, 1) == ":" or rel:sub(-1) == "/" or rel:find("//", 1, true) then
    return false
  end
  for _, part in ipairs(split_path(rel)) do
    if part == "." or part == ".." or part == "" then
      return false
    end
  end
  return true
end

local function remote_path_for_rel(rel)
  if rel == "" then
    return ":"
  end
  return ":/" .. rel
end

local function glob_to_lua_pattern(glob)
  local out = { "^" }
  local i = 1
  local magic_chars = "^$()%.[]+-"
  while i <= #glob do
    local c = glob:sub(i, i)
    if c == "*" then
      table.insert(out, ".*")
    elseif c == "?" then
      table.insert(out, ".")
    elseif magic_chars:find(c, 1, true) then
      table.insert(out, "%" .. c)
    else
      table.insert(out, c)
    end
    i = i + 1
  end
  table.insert(out, "$")
  return table.concat(out)
end

local function matches_ignore(rel, is_dir, patterns)
  if rel == "" then
    return false
  end

  local parts = split_path(rel)
  for _, raw_pattern in ipairs(patterns or {}) do
    local pattern = vim.trim(raw_pattern)
    if pattern ~= "" then
      local lua_pat = glob_to_lua_pattern(pattern)
      if pattern:find("/", 1, true) then
        if rel:match(lua_pat) then
          return true
        end
      else
        for _, part in ipairs(parts) do
          if part:match(lua_pat) then
            return true
          end
        end
      end

      if is_dir and pattern == rel .. "/" then
        return true
      end
    end
  end

  return false
end

local function collect_local_tree(local_root, patterns)
  local root_real = vim.loop.fs_realpath(local_root)
  if not root_real then
    return nil, "Local directory does not exist: " .. local_root
  end

  local root_stat = vim.loop.fs_stat(root_real)
  if not root_stat or root_stat.type ~= "directory" then
    return nil, "Local directory is not a directory: " .. root_real
  end

  local result = {
    root = root_real,
    dirs = {},
    files = {},
    ignored = {},
    skipped_symlinks = {},
  }

  local function walk(abs_dir, rel_dir)
    local handle = vim.loop.fs_scandir(abs_dir)
    if not handle then
      return false, "Failed to read local directory: " .. abs_dir
    end

    while true do
      local name, _ = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end

      local rel = rel_dir == "" and name or (rel_dir .. "/" .. name)
      if not rel_is_safe(rel) then
        return false, "Unsafe local path entry: " .. rel
      end

      local abs = abs_dir .. "/" .. name
      local stat = vim.loop.fs_lstat(abs)
      if not stat then
        return false, "Failed to stat local path: " .. abs
      end

      if stat.type == "link" then
        table.insert(result.skipped_symlinks, rel)
      elseif stat.type == "directory" then
        if matches_ignore(rel, true, patterns) then
          table.insert(result.ignored, rel .. "/")
        else
          result.dirs[rel] = true
          local ok, err = walk(abs, rel)
          if not ok then
            return false, err
          end
        end
      elseif stat.type == "file" then
        if matches_ignore(rel, false, patterns) then
          table.insert(result.ignored, rel)
        else
          result.files[rel] = abs
        end
      end
    end

    return true
  end

  local ok, err = walk(root_real, "")
  if not ok then
    return nil, err
  end

  table.sort(result.ignored)
  table.sort(result.skipped_symlinks)
  return result
end

local function collect_remote_tree(remote_root, callback)
  local out = {
    dirs = {},
    files = {},
  }

  local function walk(path, rel, done)
    M.list(path, function(ok, entries, err)
      if not ok then
        done(false, err)
        return
      end

      local i = 1
      local function iterate()
        local e = entries[i]
        if not e then
          done(true)
          return
        end
        i = i + 1

        if e.name == "." or e.name == ".." then
          iterate()
          return
        end

        local child_rel = rel == "" and e.name or (rel .. "/" .. e.name)
        if not rel_is_safe(child_rel) then
          done(false, "Unsafe remote path entry: " .. child_rel)
          return
        end

        local child_remote = M.join_remote_path(path, e.name)
        if e.type == "dir" then
          out.dirs[child_rel] = child_remote
          walk(child_remote, child_rel, function(rec_ok, rec_err)
            if not rec_ok then
              done(false, rec_err)
              return
            end
            iterate()
          end)
        else
          out.files[child_rel] = child_remote
          iterate()
        end
      end

      iterate()
    end)
  end

  walk(remote_root, "", function(ok, err)
    if not ok then
      callback(false, nil, err)
      return
    end
    callback(true, out, nil)
  end)
end

local function sorted_paths_from_set(set, child_first)
  local arr = {}
  for path, _ in pairs(set) do
    table.insert(arr, path)
  end

  table.sort(arr, function(a, b)
    local da = path_depth(a)
    local db = path_depth(b)
    if da ~= db then
      if child_first then
        return da > db
      end
      return da < db
    end
    return a < b
  end)

  return arr
end

local function sorted_uploads(files_map)
  local arr = {}
  for rel, local_path in pairs(files_map) do
    table.insert(arr, {
      rel_path = rel,
      local_path = local_path,
      remote_path = remote_path_for_rel(rel),
    })
  end
  table.sort(arr, function(a, b)
    return a.rel_path < b.rel_path
  end)
  return arr
end

local function plan_summary(plan)
  return {
    create_dirs = #plan.create_dirs,
    upload_files = #plan.upload_files,
    delete_files = #plan.delete_files,
    delete_dirs = #plan.delete_dirs,
    type_conflicts = #plan.type_conflicts,
    ignored = #plan.ignored,
    skipped_symlinks = #plan.skipped_symlinks,
  }
end

function M.plan_directory_sync(local_dir, remote_root, opts, callback)
  opts = opts or {}
  callback = callback or function() end

  local normalized_root = normalize_remote_root(remote_root)
  if not normalized_root then
    callback(false, nil, "Directory sync destination must be remote root ':'")
    return
  end

  local ignore_patterns = {}
  for _, p in ipairs(opts.ignore_patterns or {}) do
    table.insert(ignore_patterns, p)
  end

  local local_tree, local_err = collect_local_tree(local_dir, ignore_patterns)
  if not local_tree then
    callback(false, nil, local_err)
    return
  end

  collect_remote_tree(normalized_root, function(success, remote_tree, remote_err)
    if not success then
      callback(false, nil, remote_err)
      return
    end

    local create_dirs_set = {}
    local delete_files_set = {}
    local delete_dirs_set = {}
    local type_conflicts = {}

    for rel, _ in pairs(local_tree.dirs) do
      local has_remote_dir = remote_tree.dirs[rel] ~= nil
      local has_remote_file = remote_tree.files[rel] ~= nil
      if has_remote_file then
        table.insert(type_conflicts, {
          rel_path = rel,
          local_type = "dir",
          remote_type = "file",
        })
        delete_files_set[rel] = true
      end
      if not has_remote_dir then
        create_dirs_set[rel] = true
      end
    end

    for rel, _ in pairs(local_tree.files) do
      if remote_tree.dirs[rel] then
        table.insert(type_conflicts, {
          rel_path = rel,
          local_type = "file",
          remote_type = "dir",
        })
        delete_dirs_set[rel] = true
      end
    end

    for _, conflict in ipairs(type_conflicts) do
      if conflict.local_type == "dir" and conflict.remote_type == "file" then
        delete_files_set[conflict.rel_path] = nil
      elseif conflict.local_type == "file" and conflict.remote_type == "dir" then
        delete_dirs_set[conflict.rel_path] = nil
      end
    end

    for rel, _ in pairs(remote_tree.files) do
      if not local_tree.files[rel] and not local_tree.dirs[rel] then
        delete_files_set[rel] = true
      end
    end

    for rel, _ in pairs(remote_tree.dirs) do
      if not local_tree.dirs[rel] and not local_tree.files[rel] then
        delete_dirs_set[rel] = true
      end
    end

    table.sort(type_conflicts, function(a, b)
      return a.rel_path < b.rel_path
    end)

    plan_seq = plan_seq + 1
    local plan = {
      id = plan_seq,
      kind = "directory_sync_plan",
      local_root = local_tree.root,
      remote_root = normalized_root,
      ignore_patterns = ignore_patterns,
      ignored = local_tree.ignored,
      skipped_symlinks = local_tree.skipped_symlinks,
      create_dirs = {},
      upload_files = sorted_uploads(local_tree.files),
      delete_files = {},
      delete_dirs = {},
      type_conflicts = type_conflicts,
      applied = false,
    }

    for _, rel in ipairs(sorted_paths_from_set(create_dirs_set, false)) do
      table.insert(plan.create_dirs, {
        rel_path = rel,
        remote_path = remote_path_for_rel(rel),
      })
    end
    for _, rel in ipairs(sorted_paths_from_set(delete_files_set, false)) do
      table.insert(plan.delete_files, {
        rel_path = rel,
        remote_path = remote_path_for_rel(rel),
      })
    end
    for _, rel in ipairs(sorted_paths_from_set(delete_dirs_set, true)) do
      table.insert(plan.delete_dirs, {
        rel_path = rel,
        remote_path = remote_path_for_rel(rel),
      })
    end

    plan.summary = plan_summary(plan)
    callback(true, plan, nil)
  end)
end

local function validate_plan(plan)
  if type(plan) ~= "table" or plan.kind ~= "directory_sync_plan" then
    return false, "Invalid sync plan object"
  end
  if plan.applied then
    return false, "Sync plan already applied/consumed"
  end
  if normalize_remote_root(plan.remote_root) ~= ":" then
    return false, "Sync plan remote_root must be ':'"
  end

  local local_root = plan.local_root
  if type(local_root) ~= "string" or local_root == "" then
    return false, "Sync plan local_root is required"
  end
  local local_root_real = vim.loop.fs_realpath(local_root)
  if not local_root_real then
    return false, "Sync plan local_root does not exist"
  end
  local local_root_stat = vim.loop.fs_stat(local_root_real)
  if not local_root_stat or local_root_stat.type ~= "directory" then
    return false, "Sync plan local_root must be a directory"
  end

  local function validate_rel_and_remote(item, label)
    if type(item) ~= "table" then
      return false, label .. " entry must be a table"
    end
    if type(item.rel_path) ~= "string" or item.rel_path == "" or not rel_is_safe(item.rel_path) then
      return false, label .. " has unsafe rel_path"
    end
    local expected_remote = remote_path_for_rel(item.rel_path)
    if item.remote_path ~= expected_remote then
      return false, label .. " has invalid remote_path for rel_path"
    end
    return true
  end

  for _, item in ipairs(plan.create_dirs or {}) do
    local ok, err = validate_rel_and_remote(item, "create_dirs")
    if not ok then
      return false, err
    end
  end

  for _, item in ipairs(plan.delete_files or {}) do
    local ok, err = validate_rel_and_remote(item, "delete_files")
    if not ok then
      return false, err
    end
  end

  for _, item in ipairs(plan.delete_dirs or {}) do
    local ok, err = validate_rel_and_remote(item, "delete_dirs")
    if not ok then
      return false, err
    end
  end

  for _, item in ipairs(plan.upload_files or {}) do
    local ok, err = validate_rel_and_remote(item, "upload_files")
    if not ok then
      return false, err
    end
    if type(item.local_path) ~= "string" or item.local_path == "" then
      return false, "upload_files has invalid local_path"
    end

    local local_real = vim.loop.fs_realpath(item.local_path)
    if not local_real then
      return false, "upload_files local_path does not exist"
    end
    local local_stat = vim.loop.fs_stat(local_real)
    if not local_stat or local_stat.type ~= "file" then
      return false, "upload_files local_path must be a file"
    end

    local prefix = local_root_real .. "/"
    if local_real ~= local_root_real and local_real:sub(1, #prefix) ~= prefix then
      return false, "upload_files local_path escapes local_root"
    end
  end

  for _, item in ipairs(plan.type_conflicts or {}) do
    if
      type(item) ~= "table"
      or type(item.rel_path) ~= "string"
      or item.rel_path == ""
      or not rel_is_safe(item.rel_path)
    then
      return false, "type_conflicts has unsafe rel_path"
    end
    local local_type = item.local_type
    local remote_type = item.remote_type
    local valid = (local_type == "dir" and remote_type == "file") or (local_type == "file" and remote_type == "dir")
    if not valid then
      return false, "type_conflicts contains unknown type combination"
    end
  end

  return true
end

function M.apply_directory_sync(plan, callback, on_progress)
  callback = callback or function() end
  on_progress = on_progress or function() end

  local valid, err = validate_plan(plan)
  if not valid then
    callback(false, err)
    return
  end

  -- One-shot plans are consumed on first apply attempt, even if it fails.
  plan.applied = true

  local steps = {}
  local deleted_remote_paths = {}

  local function enqueue_delete(kind, rel_path)
    local remote_path = remote_path_for_rel(rel_path)
    if deleted_remote_paths[remote_path] then
      return
    end
    deleted_remote_paths[remote_path] = true
    table.insert(steps, {
      kind = kind,
      rel_path = rel_path,
      remote_path = remote_path,
    })
  end

  local conflict_file_roots = {}
  local conflict_dir_roots = {}
  for _, item in ipairs(plan.type_conflicts or {}) do
    if item.local_type == "dir" and item.remote_type == "file" then
      conflict_file_roots[item.rel_path] = true
    elseif item.local_type == "file" and item.remote_type == "dir" then
      conflict_dir_roots[item.rel_path] = true
    end
  end

  local function is_under_conflict_dir(rel_path)
    for root, _ in pairs(conflict_dir_roots) do
      if rel_path == root or rel_path:sub(1, #root + 1) == (root .. "/") then
        return true
      end
    end
    return false
  end

  -- Conflict resolution first.
  for rel_path, _ in pairs(conflict_file_roots) do
    enqueue_delete("delete_file", rel_path)
  end

  for _, item in ipairs(plan.delete_files or {}) do
    if is_under_conflict_dir(item.rel_path) then
      enqueue_delete("delete_file", item.rel_path)
    end
  end
  for _, item in ipairs(plan.delete_dirs or {}) do
    if is_under_conflict_dir(item.rel_path) then
      enqueue_delete("delete_dir", item.rel_path)
    end
  end
  for rel_path, _ in pairs(conflict_dir_roots) do
    enqueue_delete("delete_dir", rel_path)
  end

  -- Create and upload after conflict paths are clean.
  for _, item in ipairs(plan.create_dirs or {}) do
    table.insert(steps, { kind = "create_dir", rel_path = item.rel_path, remote_path = item.remote_path })
  end
  for _, item in ipairs(plan.upload_files or {}) do
    table.insert(steps, {
      kind = "upload_file",
      rel_path = item.rel_path,
      remote_path = item.remote_path,
      local_path = item.local_path,
    })
  end

  -- Ordinary extras are deleted only after successful create/upload phase.
  for _, item in ipairs(plan.delete_files or {}) do
    if not is_under_conflict_dir(item.rel_path) and not conflict_file_roots[item.rel_path] then
      enqueue_delete("delete_file", item.rel_path)
    end
  end
  for _, item in ipairs(plan.delete_dirs or {}) do
    if not is_under_conflict_dir(item.rel_path) and not conflict_dir_roots[item.rel_path] then
      enqueue_delete("delete_dir", item.rel_path)
    end
  end

  local total = #steps
  local index = 1

  local function fail_partial(step, message)
    callback(
      false,
      string.format("Partial sync failure at %s %s: %s", step.kind, step.rel_path, message or "unknown error")
    )
  end

  local function run_next()
    local step = steps[index]
    if not step then
      callback(true, nil)
      return
    end

    on_progress(index, total, step)

    local function on_step_done(ok, step_err)
      if not ok then
        fail_partial(step, step_err)
        return
      end
      index = index + 1
      run_next()
    end

    if step.kind == "create_dir" then
      M.mkdir(step.remote_path, on_step_done)
    elseif step.kind == "upload_file" then
      M.upload(step.local_path, step.remote_path, on_step_done)
    elseif step.kind == "delete_file" then
      M.delete(step.remote_path, on_step_done)
    elseif step.kind == "delete_dir" then
      jobs.execute({ "fs", "rmdir", step.remote_path }, function(ok, _, errors)
        on_step_done(ok, ok and nil or (errors or "rmdir failed"))
      end)
    else
      fail_partial(step, "unknown step kind")
    end
  end

  run_next()
end

-- Parse the output of `mpremote fs ls`
-- Returns array of {name, type, size} entries
local function parse_ls_output(output)
  local entries = {}

  for line in output:gmatch("[^\r\n]+") do
    -- mpremote fs ls output format varies, handle common patterns
    -- Example: "ls :/"
    -- boot.py
    -- main.py
    -- Or with details: "boot.py 123"

    local trimmed = vim.trim(line)
    if trimmed ~= "" and not is_ls_header_line(trimmed) then
      local name, size = trimmed:match("^(%S+)%s+(%d+)$")
      if not name then
        size, name = trimmed:match("^(%d+)%s+(.+)$")
      end
      if name then
        name = vim.trim(name)
        local is_dir = name:match("/$")
        name = name:gsub("/+$", "")
        table.insert(entries, {
          name = name,
          type = is_dir and "dir" or "file",
          size = tonumber(size),
        })
      else
        -- No size info, just name
        name = trimmed:match("^(%S+)/?$")
        if name then
          local is_dir = trimmed:match("/$")
          name = name:gsub("/+$", "")
          table.insert(entries, {
            name = name,
            type = is_dir and "dir" or "file",
            size = nil,
          })
        end
      end
    end
  end

  return entries
end

-- Join a remote base path and child name using mpremote's ':' remote path
-- convention. Examples: ':' + 'main.py' => ':main.py', ':lib' + 'x.py'
-- => ':lib/x.py'. If name is already a remote path it is returned unchanged.
function M.join_remote_path(base, name)
  base = base or ":"

  if not name or name == "" then
    return base
  end

  if name:match("^:") then
    return name
  end

  if base == ":" then
    return ":" .. name
  end

  if base:match("/$") then
    return base .. name
  end

  return base .. "/" .. name
end

-- Return the parent remote path, staying at ':' when already at root.
function M.parent_remote_path(path)
  path = path or ":"

  if path == ":" or path == ":/" then
    return ":"
  end

  path = path:gsub("/+$", "")
  local parent = path:match("^(.+)/[^/]+$")

  if not parent or parent == "" or parent == ":" then
    return ":"
  end

  return parent
end

-- Build a stable local cache path for a remote file without filename collisions.
function M.cache_path_for(remote_path, base_dir)
  local filename = M.remote_basename(remote_path)
  if filename == "" then
    filename = "remote"
  end

  local temp_dir = base_dir or (vim.fn.stdpath("cache") .. "/mpwrap")
  local digest = vim.fn.sha256(remote_path)
  return temp_dir .. "/" .. digest:sub(1, 12) .. "_" .. filename
end

function M.remote_basename(remote_path)
  local path = (remote_path or ""):gsub("^:", "")
  path = path:gsub("/+$", "")
  local filename = vim.fn.fnamemodify(path, ":t")
  return filename:gsub("^:", "")
end

-- List files on device
-- @param path string: Remote path (default ":")
-- @param callback function: Called with (success, entries, error)
function M.list(path, callback)
  path = path or ":"

  jobs.execute({ "fs", "ls", path }, function(success, output, errors)
    if success then
      local entries = parse_ls_output(output)
      callback(true, entries, nil)
    else
      callback(false, {}, errors or "Failed to list files")
    end
  end)
end

-- Upload file to device
-- @param local_path string: Local file path
-- @param remote_path string: Remote destination path
-- @param callback function: Called with (success, error)
function M.upload(local_path, remote_path, callback)
  -- Ensure local file exists
  if vim.fn.filereadable(local_path) ~= 1 then
    if callback then
      callback(false, "Local file not found: " .. local_path)
    end
    return
  end

  jobs.execute({ "fs", "cp", local_path, remote_path }, function(success, _, errors)
    if callback then
      callback(success, success and nil or (errors or "Upload failed"))
    end
  end)
end

-- Download file from device
-- @param remote_path string: Remote file path
-- @param local_path string: Local destination path
-- @param callback function: Called with (success, error)
function M.download(remote_path, local_path, callback, opts_or_force)
  local force = normalize_force(opts_or_force)

  if not force and vim.fn.filereadable(local_path) == 1 then
    if callback then
      callback(false, "Local file exists: " .. local_path)
    end
    return
  end

  local local_dir = vim.fn.fnamemodify(local_path, ":h")
  if local_dir ~= "" and vim.fn.isdirectory(local_dir) ~= 1 then
    vim.fn.mkdir(local_dir, "p")
  end

  jobs.execute({ "fs", "cp", remote_path, local_path }, function(success, _, errors)
    if callback then
      if success then
        callback(true, nil)
      else
        callback(false, errors or "Download failed")
      end
    end
  end)
end

-- Delete file on device
-- @param remote_path string: Remote file path
-- @param callback function: Called with (success, error)
function M.delete(remote_path, callback)
  jobs.execute({ "fs", "rm", remote_path }, function(success, _, errors)
    if callback then
      callback(success, success and nil or (errors or "Delete failed"))
    end
  end)
end

-- Create directory on device
-- @param remote_path string: Remote directory path
-- @param callback function: Called with (success, error)
function M.mkdir(remote_path, callback)
  jobs.execute({ "fs", "mkdir", remote_path }, function(success, _, errors)
    if callback then
      callback(success, success and nil or (errors or "mkdir failed"))
    end
  end)
end

-- Recursively delete everything under `path`, leaving `path` itself intact.
-- mpremote's `fs rm`/`fs rmdir` have no recursive flag, so this walks the
-- listing, deletes files, and recurses into + rmdirs subdirectories.
-- Sequential (one command in flight at a time) for simple error reporting.
-- @param path string: Remote directory to empty
-- @param callback function: Called with (success, error)
function M.clear_directory(path, callback)
  path = path or ":"

  M.list(path, function(list_success, entries, list_error)
    if not list_success then
      if callback then
        callback(false, list_error)
      end
      return
    end

    local function process(index)
      if index > #entries then
        if callback then
          callback(true)
        end
        return
      end

      local entry = entries[index]
      local remote_path = M.join_remote_path(path, entry.name)

      if entry.type == "dir" then
        M.clear_directory(remote_path, function(ok, err)
          if not ok then
            if callback then
              callback(false, err)
            end
            return
          end

          jobs.execute({ "fs", "rmdir", remote_path }, function(rmdir_ok, _, rmdir_errors)
            if not rmdir_ok then
              if callback then
                callback(false, rmdir_errors or "rmdir failed")
              end
              return
            end
            process(index + 1)
          end)
        end)
      else
        M.delete(remote_path, function(ok, err)
          if not ok then
            if callback then
              callback(false, err)
            end
            return
          end
          process(index + 1)
        end)
      end
    end

    process(1)
  end)
end

-- Get file from device and open in buffer
-- Downloads to temp location and opens in Neovim
-- @param remote_path string: Remote file path
-- @param callback function: Called with (success, local_path, error)
function M.open_remote_file(remote_path, callback, opts)
  opts = opts or {}
  local local_path
  local is_cache_target = false

  if opts.local_path then
    local_path = opts.local_path
  elseif opts.use_cwd then
    local_path = vim.fn.getcwd(-1, -1) .. "/" .. M.remote_basename(remote_path)
  else
    local temp_dir = vim.fn.stdpath("cache") .. "/mpwrap"
    vim.fn.mkdir(temp_dir, "p")
    local_path = M.cache_path_for(remote_path)
    is_cache_target = true
  end

  if is_cache_target then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == local_path then
        if vim.bo[bufnr].modified then
          vim.schedule(function()
            local target_ok, target_err = validate_target_window(opts.winid)
            if not target_ok then
              if callback then
                callback(false, nil, target_err)
              end
              return
            end

            if opts.winid then
              vim.api.nvim_set_current_win(opts.winid)
            end
            vim.api.nvim_set_current_buf(bufnr)
            vim.b.mpwrap_source = remote_path
            if callback then
              callback(true, local_path, nil)
            end
          end)
          return
        end
      end
    end
  end

  M.download(remote_path, local_path, function(success, error)
    if success then
      -- Open in new buffer
      vim.schedule(function()
        local target_ok, target_err = validate_target_window(opts.winid)
        if not target_ok then
          if callback then
            callback(false, nil, target_err)
          end
          return
        end

        if opts.winid then
          vim.api.nvim_set_current_win(opts.winid)
        end
        local ok, edit_err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(local_path))
        if not ok then
          if callback then
            callback(false, nil, tostring(edit_err))
          end
          return
        end
        -- Store metadata for potential upload
        vim.b.mpwrap_source = remote_path
        if callback then
          callback(true, local_path, nil)
        end
      end)
    else
      if callback then
        callback(false, nil, error)
      end
    end
  end, { force = is_cache_target })
end

-- Upload current buffer to device
-- If buffer has mpwrap_source metadata, uploads there
-- Otherwise prompts for remote path
-- @param remote_path string: Optional remote path (uses buffer metadata if nil)
-- @param callback function: Called with (success, error)
function M.upload_current_buffer(remote_path, callback)
  local bufnr = vim.api.nvim_get_current_buf()
  return M.upload_buffer(bufnr, remote_path, callback)
end

-- Upload a specific buffer to device.
-- If buffer has mpwrap_source metadata, uploads there.
-- Otherwise derives a remote path from the filename.
function M.upload_buffer(bufnr, remote_path, callback)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    if callback then
      callback(false, "Buffer is no longer valid")
    end
    return
  end
  local local_path = vim.api.nvim_buf_get_name(bufnr)

  if local_path == "" then
    if callback then
      callback(false, "Buffer has no associated file")
    end
    return
  end

  if local_path:match("^mpwrap://") then
    if callback then
      callback(false, "Select a real file buffer to upload, not the mpwrap panel")
    end
    return
  end

  -- Use metadata or provided path
  remote_path = remote_path or vim.b[bufnr].mpwrap_source

  if not remote_path then
    -- Derive from filename
    local filename = vim.fn.fnamemodify(local_path, ":t")
    remote_path = ":/" .. filename
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local eol = vim.bo[bufnr].endofline
  local fixeol = vim.bo[bufnr].fixeol
  local temp_path = vim.fn.tempname() .. ".mpwrap-upload"

  local payload
  if #lines == 0 then
    payload = ""
  else
    payload = table.concat(lines, "\n")
    if eol or fixeol then
      payload = payload .. "\n"
    end
  end

  local fd = vim.loop.fs_open(temp_path, "w", 420)
  if not fd then
    if callback then
      callback(false, "Failed to create temporary upload snapshot")
    end
    return
  end

  local written, write_error = vim.loop.fs_write(fd, payload, -1)
  vim.loop.fs_close(fd)
  if not written or written ~= #payload then
    vim.loop.fs_unlink(temp_path)
    if callback then
      callback(false, "Failed to write temporary upload snapshot: " .. tostring(write_error or "short write"))
    end
    return
  end

  M.upload(temp_path, remote_path, function(success, error)
    vim.loop.fs_unlink(temp_path)
    if callback then
      callback(success, error)
    end
  end)
end

-- Expose parser for lightweight headless tests.
M._parse_ls_output = parse_ls_output

return M
