-- Test runner: dofile()s every tests/*_spec.lua in one headless Neovim
-- process, reports pass/fail per file, and exits non-zero (via cquit) if
-- any failed - this is what scripts/test.sh (and CI) actually checks.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local spec_files = {
  "fs_spec.lua",
  "config_spec.lua",
  "init_spec.lua",
  "devices_spec.lua",
  "jobs_spec.lua",
  "repl_spec.lua",
  "sync_spec.lua",
  "panel_spec.lua",
}

local failed = {}

for _, name in ipairs(spec_files) do
  local path = vim.fn.getcwd() .. "/tests/" .. name
  local ok, err = pcall(dofile, path)
  if ok then
    print(string.format("[PASS] %s", name))
  else
    print(string.format("[FAIL] %s: %s", name, tostring(err)))
    table.insert(failed, name)
  end
end

print("")
if #failed > 0 then
  print(string.format("%d/%d spec file(s) failed: %s", #failed, #spec_files, table.concat(failed, ", ")))
  vim.cmd("cquit 1")
else
  print(string.format("All %d spec files passed.", #spec_files))
  vim.cmd("qa!")
end
