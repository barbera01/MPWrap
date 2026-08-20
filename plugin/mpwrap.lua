-- Plugin entry point
-- This file is loaded automatically by Neovim

-- Prevent loading plugin multiple times
if vim.g.loaded_mpwrap then
  return
end
vim.g.loaded_mpwrap = 1

-- Ensure Neovim version compatibility
if vim.fn.has("nvim-0.8.0") ~= 1 then
  vim.notify("mpwrap.nvim requires Neovim >= 0.8.0", vim.log.levels.ERROR)
  return
end

-- Plugin is lazy-loaded; setup() must be called by user
-- This file just marks the plugin as loaded

local ok, health = pcall(require, "mpwrap.health")
if ok and vim.fn.has("nvim-0.8.0") == 1 then
  vim.api.nvim_create_user_command("MpWrapHealth", function()
    health.check()
  end, { desc = "Run mpwrap.nvim health check" })
end
