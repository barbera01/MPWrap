-- Shared assertions for tests/*_spec.lua. No test framework dependency -
-- these just error() on failure, which scripts/test.sh treats as a failed
-- spec file (headless nvim exits non-zero when a script-sourced file errors).
local M = {}

function M.assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", message, tostring(expected), tostring(actual)), 2)
  end
end

function M.assert_true(value, message)
  if not value then
    error(message, 2)
  end
end

function M.assert_match(value, pattern, message)
  if tostring(value):match(pattern) == nil then
    error(string.format("%s: expected %q to match %q", message, tostring(value), pattern), 2)
  end
end

return M
