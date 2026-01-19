std = "luajit"
-- Luacheck configuration for Neovim plugins

-- Neovim globals (use globals instead of read_globals to allow writing to vim.bo, vim.wo, vim.g, vim.b)
globals = {
  "vim",
}

-- Don't report unused self arguments
self = false

-- Max line length
max_line_length = 150

-- Ignore some warnings
ignore = {
  "212", -- Unused argument (common in callbacks)
  "213", -- Unused loop variable
  "631", -- Line is too long (handled separately)
}

-- Exclude files
exclude_files = {
  ".luarocks",
  "lua_modules",
}
