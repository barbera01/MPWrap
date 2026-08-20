vim.opt.runtimepath:prepend(vim.fn.getcwd())

local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
local assert_true = helpers.assert_true
local assert_equal = helpers.assert_equal
local assert_match = helpers.assert_match

local repl = require("mpwrap.repl")
local jobs = require("mpwrap.jobs")
local config = require("mpwrap.config")

config.setup({ device = "/dev/mock" })

local existing = jobs.current_device_lease()
if existing then
  jobs.release_device_lease(existing.token)
end

local original_termopen = vim.fn.termopen
local original_jobwait = vim.fn.jobwait
local original_jobstop = vim.fn.jobstop

local running = false
local on_exit_cb
local next_job_id = 4200

vim.fn.termopen = function(_cmd, opts)
  on_exit_cb = opts.on_exit
  running = true
  next_job_id = next_job_id + 1
  return next_job_id
end

vim.fn.jobwait = function(_jobs, _timeout)
  if running then
    return { -1 }
  end
  return { 0 }
end

vim.fn.jobstop = function(_job)
  running = false
  if on_exit_cb then
    on_exit_cb(nil, 0, nil)
  end
  return 1
end

local winid = vim.api.nvim_get_current_win()
local exit_code

local ok, err = repl.create(winid, {
  on_exit = function(code)
    exit_code = code
  end,
})
assert_true(ok == true, "repl.create should succeed with mocked termopen: " .. tostring(err))
assert_true(repl.state.lease_token ~= nil, "repl must hold a lease while running")

local bad_ok, bad_err = repl.create(nil, { on_exit = function() end })
assert_true(bad_ok == false, "repl.create(nil) should fail")
assert_match(bad_err or "", "target window", "repl.create(nil) should report invalid target window")

running = false
if on_exit_cb then
  on_exit_cb(nil, 0, nil)
end
vim.wait(100, function()
  return exit_code ~= nil
end, 10)

assert_equal(exit_code, 0, "on_exit callback should receive natural exit code")
assert_true(repl.state.job_id == nil, "job_id should clear on natural exit")
assert_true(repl.state.lease_token == nil, "lease should release on natural exit")
assert_true(repl.state.bufnr == nil, "terminal buffer should be cleaned up on natural exit")

-- Stale on_exit callback must not clear a newer REPL instance.
local first_exit_cb
ok = repl.create(winid, { on_exit = function() end })
assert_true(ok == true, "second repl.create should succeed")
first_exit_cb = on_exit_cb

repl.stop()
vim.wait(100, function()
  return jobs.current_device_lease() == nil
end, 10)
ok = repl.create(winid, { on_exit = function() end })
assert_true(ok == true, "third repl.create should succeed after stop")
local active_token = repl.state.lease_token

running = false
first_exit_cb(nil, 0, nil)
vim.wait(50, function()
  return false
end, 10)

assert_true(repl.state.lease_token == active_token, "stale callback must not clear new lease")

repl.stop()
vim.wait(100, function()
  return jobs.current_device_lease() == nil
end, 10)

vim.fn.termopen = original_termopen
vim.fn.jobwait = original_jobwait
vim.fn.jobstop = original_jobstop

print("repl_spec passed")
