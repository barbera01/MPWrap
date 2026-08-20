vim.opt.runtimepath:prepend(vim.fn.getcwd())

local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
local assert_true = helpers.assert_true
local assert_match = helpers.assert_match

local jobs = require("mpwrap.jobs")

-- Reset lease state if a prior spec leaked it.
local existing = jobs.current_device_lease()
if existing then
  jobs.release_device_lease(existing.token)
end

local token = assert(jobs.acquire_device_lease({ label = "spec-owner" }))
local token2, err = jobs.acquire_device_lease({ label = "other-owner" })
assert_true(token2 == nil, "second lease acquisition should fail")
assert_match(err or "", "busy", "lease conflict should report busy")

assert_true(jobs.release_device_lease(token + 1) == false, "stale token must not release active lease")
assert_true(jobs.current_device_lease() ~= nil, "lease should still be held after stale release")
assert_true(jobs.release_device_lease(token) == true, "correct token should release lease")

local held = assert(jobs.acquire_device_lease({ label = "manual-hold" }))
local callback_done = false
local callback_success
local callback_error

local job_id = jobs.execute({ "fs", "ls", ":" }, function(success, _, errors)
  callback_done = true
  callback_success = success
  callback_error = errors
end)

assert_true(job_id <= 0, "execute should fail-fast while lease is held")
vim.wait(200, function()
  return callback_done
end, 10)
assert_true(callback_success == false, "execute fail-fast callback should report failure")
assert_match(callback_error or "", "busy", "execute fail-fast callback should explain lock contention")

jobs.release_device_lease(held)

print("jobs_spec passed")
