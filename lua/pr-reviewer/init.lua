local M = {}

local github = require("pr-reviewer.github")
local git = require("pr-reviewer.git")
local ui = require("pr-reviewer.ui")

M.config = {
  branch_prefix = "reviewing_",
  picker = "native", -- "native", "fzf-lua", "telescope"
  open_files_on_review = false, -- open modified files in quickfix after merge
  show_comments = true, -- show PR comments in buffers during review
  show_icons = true, -- show icons in UI elements
  show_inline_diff = true, -- show inline diff in buffers (old lines as virtual text)
  mark_as_viewed_key = "<CR>", -- key to mark file as viewed and go to next file
  next_hunk_key = "<C-j>", -- key to jump to next hunk
  prev_hunk_key = "<C-k>", -- key to jump to previous hunk
  next_file_key = "<C-l>", -- key to go to next file in quickfix
  prev_file_key = "<C-h>", -- key to go to previous file in quickfix

  -- Review buffer settings
  review_buffer = {
    position = "left", -- "left", "right", "top", "bottom"
    width = 50, -- width for left/right
    height = 20, -- height for top/bottom
    group_by_directory = true, -- group files by directory
    sort_by = "path", -- "path", "status", "changes"
    filter_viewed_key = "fv", -- filter: show only viewed
    filter_not_viewed_key = "fn", -- filter: show only not viewed
    filter_all_key = "fa", -- filter: show all
    open_split_key = "s", -- open file in horizontal split
    open_vsplit_key = "v", -- open file in vertical split
    toggle_key = "<C-e>", -- toggle review buffer open/close
  },
}

local ns_id = vim.api.nvim_create_namespace("pr_review_comments")
local changes_ns_id = vim.api.nvim_create_namespace("pr_review_changes")
local diff_ns_id = vim.api.nvim_create_namespace("pr_review_diff")

M._buffer_comments = {}
M._buffer_changes = {}
M._buffer_hunks = {}
M._buffer_stats = {}
M._viewed_files = {}
M._float_win_general = nil -- General info float (file x/total)
M._float_win_buffer = nil  -- Buffer info float (hunks, stats, comments)
M._float_win_keymaps = nil -- Keymaps float
M._buffer_jumped = {} -- Track if we've already jumped to first change in buffer
M._buffer_keymaps_saved = {} -- Track if we've saved keymaps for this buffer

-- Review buffer state
M._review_buffer = nil -- Review buffer number
M._review_window = nil -- Review window ID
M._review_files = {} -- List of files with metadata
M._review_files_ordered = {} -- Ordered list matching ReviewBuffer display order
M._review_filter = "all" -- Current filter: "all", "viewed", "not_viewed"
M._review_sort = nil -- Current sort (uses config default)

local function get_session_dir()
  local data_path = vim.fn.stdpath("data")
  return data_path .. "/pr-reviewer-sessions"
end

local function get_session_file()
  local cwd = vim.fn.getcwd()
  -- Convert path to safe filename: /home/otavio/Projetos/api -> review_home_otavio_Projetos_api
  local safe_name = cwd:gsub("^/", ""):gsub("/", "_")
  return get_session_dir() .. "/review_" .. safe_name .. ".json"
end

local function save_session()
  if not vim.g.pr_review_number then
    return
  end

  local session_dir = get_session_dir()
  vim.fn.mkdir(session_dir, "p")

  local session_data = {
    pr_number = vim.g.pr_review_number,
    previous_branch = vim.g.pr_review_previous_branch,
    modified_files = vim.g.pr_review_modified_files,
    viewed_files = M._viewed_files,
    cwd = vim.fn.getcwd(),
  }

  local session_file = get_session_file()
  local json_str = vim.fn.json_encode(session_data)
  local file = io.open(session_file, "w")
  if file then
    file:write(json_str)
    file:close()
  end
end

local function load_session()
  local session_file = get_session_file()
  local file = io.open(session_file, "r")
  if not file then
    return nil
  end

  local content = file:read("*all")
  file:close()

  local ok, session_data = pcall(vim.fn.json_decode, content)
  if not ok or not session_data then
    return nil
  end

  return session_data
end

local function delete_session()
  local session_file = get_session_file()
  vim.fn.delete(session_file)
end

-- Forward declarations
local get_inline_diff

-- Collect all files from PR with their metadata
local function collect_pr_files(callback)
  -- First get tracked changes (M, A, D)
  local cmd = "git diff --name-status HEAD"
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then
        vim.schedule(function()
          callback({})
        end)
        return
      end

      local files = {}
      for _, line in ipairs(data) do
        -- Format: M\tfile/path.txt or A\tfile/path.txt or D\tfile/path.txt
        local status, path = line:match("^([AMD])%s+(.+)$")
        if status and path then
          table.insert(files, {
            path = path,
            status = status, -- M=modified, A=added, D=deleted
            viewed = M._viewed_files[path] or false,
            stats = { additions = 0, modifications = 0, deletions = 0 },
          })
        end
      end

      -- Now get untracked files
      local untracked_cmd = "git ls-files --others --exclude-standard"
      vim.fn.jobstart(untracked_cmd, {
        stdout_buffered = true,
        on_stdout = function(_, untracked_data)
          if untracked_data then
            for _, line in ipairs(untracked_data) do
              if line and line ~= "" then
                table.insert(files, {
                  path = line,
                  status = "N", -- new/untracked
                  viewed = M._viewed_files[line] or false,
                  stats = { additions = 0, modifications = 0, deletions = 0 },
                })
              end
            end
          end

          -- Now get stats for each file
          local pending = #files
          if pending == 0 then
            vim.schedule(function()
              callback(files)
            end)
            return
          end

          for _, file in ipairs(files) do
            get_inline_diff(file.path, file.status, function(hunks)
              if hunks and #hunks > 0 then
                local additions = 0
                local deletions = 0
                local modifications = 0

                for _, hunk in ipairs(hunks) do
                  local added = #hunk.added_lines
                  local removed = #hunk.removed_lines

                  if added > 0 and removed > 0 then
                    modifications = modifications + math.min(added, removed)
                    additions = additions + math.max(0, added - removed)
                    deletions = deletions + math.max(0, removed - added)
                  elseif added > 0 then
                    additions = additions + added
                  elseif removed > 0 then
                    deletions = deletions + removed
                  end
                end

                file.stats = {
                  additions = additions,
                  modifications = modifications,
                  deletions = deletions,
                }
              end

              pending = pending - 1
              if pending == 0 then
                vim.schedule(function()
                  callback(files)
                end)
              end
            end)
          end
        end,
      })
    end,
  })
end

local function get_relative_path(bufnr)
  local full_path = vim.api.nvim_buf_get_name(bufnr)
  local cwd = vim.fn.getcwd()
  if full_path:sub(1, #cwd) == cwd then
    return full_path:sub(#cwd + 2)
  end
  return full_path
end

local function get_changed_lines_for_file(file_path, status, callback)
  local cmd
  if status == "N" then
    -- For new/untracked files, compare with /dev/null
    cmd = string.format("git diff --unified=0 --no-index /dev/null -- %s", vim.fn.shellescape(file_path))
  else
    cmd = string.format("git diff --unified=0 HEAD -- %s", vim.fn.shellescape(file_path))
  end
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      local all_lines = {}
      if data then
        for _, line in ipairs(data) do
          local start_line, count = line:match("^@@%s+%-%d+[,%d]*%s+%+(%d+),?(%d*)%s+@@")
          if start_line then
            start_line = tonumber(start_line)
            count = tonumber(count) or 1
            if count == 0 then count = 1 end
            for i = 0, count - 1 do
              table.insert(all_lines, start_line + i)
            end
          end
        end
      end

      table.sort(all_lines)

      local unique_lines = {}
      local seen = {}
      for _, l in ipairs(all_lines) do
        if not seen[l] then
          seen[l] = true
          table.insert(unique_lines, l)
        end
      end

      local hunks = {}
      if #unique_lines > 0 then
        local current_hunk = { start_line = unique_lines[1], end_line = unique_lines[1] }
        for i = 2, #unique_lines do
          if unique_lines[i] == current_hunk.end_line + 1 then
            current_hunk.end_line = unique_lines[i]
          else
            table.insert(hunks, current_hunk)
            current_hunk = { start_line = unique_lines[i], end_line = unique_lines[i] }
          end
        end
        table.insert(hunks, current_hunk)
      end

      vim.schedule(function()
        callback(unique_lines, hunks)
      end)
    end,
  })
end

-- Forward declaration
local update_changes_float

get_inline_diff = function(file_path, status, callback)
  -- For new/untracked files, use a different command to get all lines
  local cmd
  if status == "A" or status == "N" then
    cmd = string.format("git diff --unified=0 --no-index /dev/null -- %s", vim.fn.shellescape(file_path))
  else
    cmd = string.format("git diff --unified=0 HEAD -- %s", vim.fn.shellescape(file_path))
  end

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then
        vim.schedule(function()
          callback({})
        end)
        return
      end

      local hunks = {}
      local current_hunk = nil
      local in_hunk = false

      for _, line in ipairs(data) do
        -- Parse hunk header: @@ -old_start,old_count +new_start,new_count @@
        local old_start, old_count, new_start, new_count = line:match("^@@%s+%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s+@@")
        if old_start then
          old_start = tonumber(old_start)
          old_count = tonumber(old_count) or 1
          new_start = tonumber(new_start)
          new_count = tonumber(new_count) or 1

          current_hunk = {
            old_start = old_start,
            old_count = old_count,
            new_start = new_start,
            new_count = new_count,
            removed_lines = {},
            added_lines = {},
          }
          table.insert(hunks, current_hunk)
          in_hunk = true
        elseif in_hunk and current_hunk then
          if line:match("^%-") and not line:match("^%-%-%- ") then
            -- Removed line
            table.insert(current_hunk.removed_lines, line:sub(2))
          elseif line:match("^%+") and not line:match("^%+%+%+ ") then
            -- Added line (current content)
            table.insert(current_hunk.added_lines, line:sub(2))
          end
        end
      end

      vim.schedule(function()
        callback(hunks)
      end)
    end,
  })
end

local function display_inline_diff(bufnr, hunks)
  if not M.config.show_inline_diff then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, diff_ns_id, 0, -1)

  for _, hunk in ipairs(hunks) do
    local new_line = hunk.new_start

    -- Show removed lines as virtual text above the first added line
    if #hunk.removed_lines > 0 then
      -- Get the indentation of the current line to match it
      local line_idx = new_line - 1
      local current_line_content = ""
      if line_idx >= 0 and line_idx < vim.api.nvim_buf_line_count(bufnr) then
        current_line_content = vim.api.nvim_buf_get_lines(bufnr, line_idx, line_idx + 1, false)[1] or ""
      end

      -- Extract leading whitespace from current line
      local indent = current_line_content:match("^%s*") or ""

      local virt_lines = {}
      for _, removed in ipairs(hunk.removed_lines) do
        -- Remove any leading whitespace from removed line and add current indent
        local stripped = removed:match("^%s*(.-)$") or removed
        table.insert(virt_lines, { { indent .. "- " .. stripped, "DiffDelete" } })
      end

      -- Place virtual lines above the first new line
      if line_idx >= 0 and line_idx < vim.api.nvim_buf_line_count(bufnr) then
        vim.api.nvim_buf_set_extmark(bufnr, diff_ns_id, line_idx, 0, {
          virt_lines_above = true,
          virt_lines = virt_lines,
        })
      end
    end

    -- Highlight added/modified lines
    for i = 0, hunk.new_count - 1 do
      local line_idx = new_line + i - 1
      if line_idx >= 0 and line_idx < vim.api.nvim_buf_line_count(bufnr) then
        vim.api.nvim_buf_set_extmark(bufnr, diff_ns_id, line_idx, 0, {
          line_hl_group = "DiffAdd",
          sign_text = "+",
          sign_hl_group = "DiffAdd",
        })
      end
    end
  end
end

local function load_inline_diff_for_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.g.pr_review_number or not M.config.show_inline_diff then
    return
  end

  local file_path = get_relative_path(bufnr)

  -- Find status from review files
  local status = "M" -- default to modified
  for _, file in ipairs(M._review_files) do
    if file.path == file_path then
      status = file.status
      break
    end
  end

  get_inline_diff(file_path, status, function(hunks)
    if hunks and #hunks > 0 then
      -- Calculate stats
      local additions = 0
      local deletions = 0
      local modifications = 0

      for _, hunk in ipairs(hunks) do
        local added = #hunk.added_lines
        local removed = #hunk.removed_lines

        if added > 0 and removed > 0 then
          -- Lines were modified
          modifications = modifications + math.min(added, removed)
          additions = additions + math.max(0, added - removed)
          deletions = deletions + math.max(0, removed - added)
        elseif added > 0 then
          -- Only additions
          additions = additions + added
        elseif removed > 0 then
          -- Only deletions
          deletions = deletions + removed
        end
      end

      M._buffer_stats[bufnr] = {
        additions = additions,
        deletions = deletions,
        modifications = modifications,
      }

      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          display_inline_diff(bufnr, hunks)
          -- Update the floating indicator immediately
          if bufnr == vim.api.nvim_get_current_buf() then
            vim.defer_fn(update_changes_float, 10)
          end
        end
      end)
    end
  end)
end

local function close_float_wins()
  if M._float_win_general and vim.api.nvim_win_is_valid(M._float_win_general) then
    vim.api.nvim_win_close(M._float_win_general, true)
  end
  if M._float_win_buffer and vim.api.nvim_win_is_valid(M._float_win_buffer) then
    vim.api.nvim_win_close(M._float_win_buffer, true)
  end
  if M._float_win_keymaps and vim.api.nvim_win_is_valid(M._float_win_keymaps) then
    vim.api.nvim_win_close(M._float_win_keymaps, true)
  end
  M._float_win_general = nil
  M._float_win_buffer = nil
  M._float_win_keymaps = nil
end

-- Group files by directory
local function group_files_by_directory(files)
  local grouped = {}
  for _, file in ipairs(files) do
    local dir = file.path:match("(.+)/[^/]+$") or "."
    if not grouped[dir] then
      grouped[dir] = {}
    end
    table.insert(grouped[dir], file)
  end
  return grouped
end

-- Render the review buffer
local function render_review_buffer()
  if not M._review_buffer or not vim.api.nvim_buf_is_valid(M._review_buffer) then
    return
  end

  -- Get current file to highlight it
  local current_file_path = nil
  local current_buf = vim.api.nvim_get_current_buf()
  if current_buf and vim.api.nvim_buf_is_valid(current_buf) then
    current_file_path = get_relative_path(current_buf)
  end

  local lines = {}
  local highlights = {}
  local file_map = {} -- Maps line number to file
  M._review_files_ordered = {} -- Reset ordered list

  -- Header
  local cfg = M.config.review_buffer
  table.insert(lines, "═══ PR Review ═══")
  table.insert(lines, "")
  table.insert(lines, string.format("[%s] Toggle | [q] Close", cfg.toggle_key))
  table.insert(lines, string.format("Filters: [%s] All  [%s] Viewed  [%s] Not Viewed", cfg.filter_all_key, cfg.filter_viewed_key, cfg.filter_not_viewed_key))
  table.insert(lines, string.format("Open: [<CR>] Current  [%s] Split  [%s] VSplit", cfg.open_split_key, cfg.open_vsplit_key))
  table.insert(lines, string.format("Sort: %s | Filter: %s", M._review_sort or cfg.sort_by, M._review_filter))
  table.insert(lines, "")

  -- Filter files based on current filter
  local filtered_files = {}
  for _, file in ipairs(M._review_files) do
    if M._review_filter == "all" then
      table.insert(filtered_files, file)
    elseif M._review_filter == "viewed" and file.viewed then
      table.insert(filtered_files, file)
    elseif M._review_filter == "not_viewed" and not file.viewed then
      table.insert(filtered_files, file)
    end
  end

  -- Group and sort
  if cfg.group_by_directory then
    local grouped = group_files_by_directory(filtered_files)
    local dirs = vim.tbl_keys(grouped)
    table.sort(dirs)

    for _, dir in ipairs(dirs) do
      table.insert(lines, string.format("📁 %s/", dir))
      table.insert(highlights, { line = #lines - 1, hl_group = "Directory" })

      for _, file in ipairs(grouped[dir]) do
        -- Add to ordered list
        table.insert(M._review_files_ordered, file)

        local filename = file.path:match("[^/]+$")
        local status_icon = file.status == "M" and "M" or (file.status == "A" and "A" or (file.status == "D" and "D" or "N"))
        local viewed_icon = file.viewed and (M.config.show_icons and "✓" or "[V]") or (M.config.show_icons and "○" or "[ ]")
        local stats_str = string.format("+%d ~%d -%d", file.stats.additions, file.stats.modifications, file.stats.deletions)

        -- Add indicator for current file
        local current_indicator = ""
        if current_file_path and file.path == current_file_path then
          current_indicator = M.config.show_icons and " ➤" or " >"
        end

        local line = string.format("  %s %s %s  %s%s", viewed_icon, status_icon, filename, stats_str, current_indicator)
        local line_idx = #lines + 1
        table.insert(lines, line)
        file_map[line_idx] = file

        -- Calculate filename position in the line for highlighting
        local filename_start = string.len("  " .. viewed_icon .. " " .. status_icon .. " ")
        local filename_end = filename_start + string.len(filename)

        -- Highlight based on status or if current file
        if current_file_path and file.path == current_file_path then
          -- Highlight entire line for current file
          table.insert(highlights, { line = line_idx - 1, hl_group = "CursorLine" })
          -- Highlight filename with special color
          table.insert(highlights, { line = line_idx - 1, hl_group = "Search", start_col = filename_start, end_col = filename_end })
        else
          -- Apply viewed dimming
          if file.viewed then
            table.insert(highlights, { line = line_idx - 1, hl_group = "Comment" })
          elseif file.status == "A" or file.status == "N" then
            table.insert(highlights, { line = line_idx - 1, hl_group = "DiffAdd" })
          elseif file.status == "D" then
            table.insert(highlights, { line = line_idx - 1, hl_group = "DiffDelete" })
          elseif file.status == "M" then
            table.insert(highlights, { line = line_idx - 1, hl_group = "DiffChange" })
          end
        end
      end
      table.insert(lines, "")
    end
  else
    -- Flat list
    for _, file in ipairs(filtered_files) do
      -- Add to ordered list
      table.insert(M._review_files_ordered, file)

      local status_icon = file.status == "M" and "M" or (file.status == "A" and "A" or (file.status == "D" and "D" or "N"))
      local viewed_icon = file.viewed and (M.config.show_icons and "✓" or "[V]") or (M.config.show_icons and "○" or "[ ]")
      local stats_str = string.format("+%d ~%d -%d", file.stats.additions, file.stats.modifications, file.stats.deletions)

      -- Add indicator for current file
      local current_indicator = ""
      if current_file_path and file.path == current_file_path then
        current_indicator = M.config.show_icons and " ➤" or " >"
      end

      local line = string.format("%s %s %s  %s%s", viewed_icon, status_icon, file.path, stats_str, current_indicator)
      local line_idx = #lines + 1
      table.insert(lines, line)
      file_map[line_idx] = file

      -- Calculate file path position in the line for highlighting
      local filepath_start = string.len(viewed_icon .. " " .. status_icon .. " ")
      local filepath_end = filepath_start + string.len(file.path)

      -- Highlight based on status or if current file
      if current_file_path and file.path == current_file_path then
        -- Highlight entire line for current file
        table.insert(highlights, { line = line_idx - 1, hl_group = "CursorLine" })
        -- Highlight filepath with special color
        table.insert(highlights, { line = line_idx - 1, hl_group = "Search", start_col = filepath_start, end_col = filepath_end })
      else
        -- Apply viewed dimming
        if file.viewed then
          table.insert(highlights, { line = line_idx - 1, hl_group = "Comment" })
        elseif file.status == "A" or file.status == "N" then
          table.insert(highlights, { line = line_idx - 1, hl_group = "DiffAdd" })
        elseif file.status == "D" then
          table.insert(highlights, { line = line_idx - 1, hl_group = "DiffDelete" })
        elseif file.status == "M" then
          table.insert(highlights, { line = line_idx - 1, hl_group = "DiffChange" })
        end
      end
    end
  end

  -- Set lines
  vim.bo[M._review_buffer].modifiable = true
  vim.api.nvim_buf_set_lines(M._review_buffer, 0, -1, false, lines)
  vim.bo[M._review_buffer].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("pr_review_buffer")
  vim.api.nvim_buf_clear_namespace(M._review_buffer, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    if hl.start_col and hl.end_col then
      -- Highlight specific range (for file name)
      vim.api.nvim_buf_add_highlight(M._review_buffer, ns, hl.hl_group, hl.line, hl.start_col, hl.end_col)
    else
      -- Highlight entire line
      vim.api.nvim_buf_add_highlight(M._review_buffer, ns, hl.hl_group, hl.line, 0, -1)
    end
  end

  -- Store file map in buffer variable
  vim.b[M._review_buffer].pr_file_map = file_map
end

-- Helper to open a file (including deleted files)
local function open_file_safe(file, split_cmd)
  -- Check if we're in the review buffer - if so, move to another window first
  local current_buf = vim.api.nvim_get_current_buf()
  if current_buf == M._review_buffer then
    -- Find a non-review window to use
    local found_window = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if buf ~= M._review_buffer and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        found_window = true
        break
      end
    end

    -- If we didn't find another window, create a new split to the right
    if not found_window then
      -- Make sure we're in the review buffer window
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == M._review_buffer then
          vim.api.nvim_set_current_win(win)
          break
        end
      end
      -- Create a new window to the right with an empty buffer
      vim.cmd("rightbelow vnew")
    elseif split_cmd then
      -- Create split in the found window
      if split_cmd == "split" then
        vim.cmd("split")
      elseif split_cmd == "vsplit" then
        vim.cmd("vsplit")
      end
    end
  elseif split_cmd then
    -- Not in review buffer, just create the split
    if split_cmd == "split" then
      vim.cmd("split")
    elseif split_cmd == "vsplit" then
      vim.cmd("vsplit")
    end
  end

  if file.status == "D" then
    -- Open deleted file from HEAD
    local cmd = string.format("git show HEAD:%s", vim.fn.shellescape(file.path))
    vim.fn.jobstart(cmd, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        vim.schedule(function()
          if not data or #data == 0 then
            vim.notify("Could not load deleted file content", vim.log.levels.ERROR)
            return
          end

          -- Create scratch buffer with old content
          local buf = vim.api.nvim_create_buf(false, true)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, data)
          vim.bo[buf].filetype = vim.filetype.match({ filename = file.path }) or ""
          vim.bo[buf].buftype = "nofile"
          vim.bo[buf].modifiable = false
          vim.api.nvim_buf_set_name(buf, file.path .. " [DELETED]")

          vim.api.nvim_set_current_buf(buf)
        end)
      end,
    })
  else
    -- Open normal file
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/" .. file.path))
  end
end

-- Open file from review buffer (handles deleted files)
local function open_file_from_review(split_type)
  local bufnr = vim.api.nvim_get_current_buf()
  local file_map = vim.b[bufnr].pr_file_map
  if not file_map or type(file_map) ~= "table" then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local file = file_map[line]

  if not file or type(file) ~= "table" or not file.path then
    return
  end

  -- Use the safe open function with split command
  open_file_safe(file, split_type)
end

-- Toggle filter
local function set_review_filter(filter)
  M._review_filter = filter
  render_review_buffer()
end

-- Setup keymaps for review buffer
local function setup_review_buffer_keymaps(bufnr)
  local cfg = M.config.review_buffer

  -- Store the callback in a global table so it can be called
  _G._pr_reviewer_open_file = function()
    open_file_from_review(nil)
  end

  -- Open file - using nvim_buf_set_keymap for compatibility
  vim.api.nvim_buf_set_keymap(bufnr, "n", "<CR>", [[<Cmd>lua _G._pr_reviewer_open_file()<CR>]], { noremap = true, silent = true, nowait = true })

  vim.keymap.set("n", cfg.open_split_key, function()
    open_file_from_review("split")
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Open file in split" })
  vim.keymap.set("n", cfg.open_vsplit_key, function()
    open_file_from_review("vsplit")
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Open file in vsplit" })

  -- Filters
  vim.keymap.set("n", cfg.filter_all_key, function() set_review_filter("all") end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Filter: all files" })
  vim.keymap.set("n", cfg.filter_viewed_key, function() set_review_filter("viewed") end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Filter: viewed files" })
  vim.keymap.set("n", cfg.filter_not_viewed_key, function() set_review_filter("not_viewed") end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Filter: not viewed files" })

  -- Note: We DON'T register mark_as_viewed_key here because:
  -- 1. In ReviewBuffer, <CR> should open files, not mark them as viewed
  -- 2. mark_as_viewed is for file buffers, not the ReviewBuffer itself
  -- 3. If user wants to mark as viewed from ReviewBuffer, they can use a different key (e.g., 'm')

  -- Optional: Add a different key for marking files as viewed from ReviewBuffer
  vim.keymap.set("n", "m", function()
    local buf = vim.api.nvim_get_current_buf()
    local file_map = vim.b[buf].pr_file_map
    if not file_map or type(file_map) ~= "table" then return end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    local file = file_map[line]

    if file and type(file) == "table" and file.path then
      file.viewed = true
      M._viewed_files[file.path] = true
      save_session()
      render_review_buffer()
      -- Move to next file
      vim.cmd("normal! j")
    end
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Mark file as viewed" })

  -- Close buffer
  vim.keymap.set("n", "q", function()
    if M._review_window and vim.api.nvim_win_is_valid(M._review_window) then
      vim.api.nvim_win_close(M._review_window, true)
    end
    M._review_window = nil
  end, { buffer = bufnr, silent = true, noremap = true, nowait = true, desc = "Close review buffer" })
end

-- Open or refresh review buffer
function M.open_review_buffer(callback)
  if not vim.g.pr_review_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  -- Collect files if not already collected
  if #M._review_files == 0 then
    collect_pr_files(function(files)
      M._review_files = files
      M.open_review_buffer(callback) -- Recursive call after files are loaded
    end)
    return
  end

  -- Create buffer if it doesn't exist
  if not M._review_buffer or not vim.api.nvim_buf_is_valid(M._review_buffer) then
    M._review_buffer = vim.api.nvim_create_buf(false, true)

    -- Try to set name, if it fails (buffer already exists), wipe the old one
    local success, err = pcall(vim.api.nvim_buf_set_name, M._review_buffer, "PR Review")
    if not success then
      -- Find and delete the existing buffer with this name
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match("PR Review$") then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      -- Try again
      vim.api.nvim_buf_set_name(M._review_buffer, "PR Review")
    end

    vim.bo[M._review_buffer].buftype = "nofile"
    vim.bo[M._review_buffer].bufhidden = "hide"
    vim.bo[M._review_buffer].swapfile = false
    -- Don't set filetype yet - it might trigger ftplugins that override keymaps
    -- vim.bo[M._review_buffer].filetype = "pr-review"

    setup_review_buffer_keymaps(M._review_buffer)
    vim.notify("Review buffer keymaps set up for buffer " .. M._review_buffer, vim.log.levels.INFO)
  end

  -- Render content
  render_review_buffer()

  -- Re-apply keymaps after rendering (in case buffer was recreated)
  setup_review_buffer_keymaps(M._review_buffer)

  -- Set modifiable to false after everything is set up
  vim.bo[M._review_buffer].modifiable = false

  -- Open window if not already open
  if not M._review_window or not vim.api.nvim_win_is_valid(M._review_window) then
    local cfg = M.config.review_buffer
    local win_cmd

    if cfg.position == "left" then
      win_cmd = string.format("topleft vertical %d split", cfg.width)
    elseif cfg.position == "right" then
      win_cmd = string.format("botright vertical %d split", cfg.width)
    elseif cfg.position == "top" then
      win_cmd = string.format("topleft %d split", cfg.height)
    else -- bottom
      win_cmd = string.format("botright %d split", cfg.height)
    end

    vim.cmd(win_cmd)
    M._review_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M._review_window, M._review_buffer)
    vim.api.nvim_win_set_option(M._review_window, "number", false)
    vim.api.nvim_win_set_option(M._review_window, "relativenumber", false)
    vim.api.nvim_win_set_option(M._review_window, "signcolumn", "no")
    vim.api.nvim_win_set_option(M._review_window, "wrap", false)

    -- Return to previous window
    vim.cmd("wincmd p")
  end

  -- Call callback if provided
  if callback then
    callback()
  end
end

-- Refresh review buffer (call when files are marked as viewed)
function M.refresh_review_buffer()
  if M._review_buffer and vim.api.nvim_buf_is_valid(M._review_buffer) then
    -- Update viewed status in files list
    for _, file in ipairs(M._review_files) do
      file.viewed = M._viewed_files[file.path] or false
    end
    render_review_buffer()
  end
end

-- Toggle review buffer (open/close)
function M.toggle_review_buffer()
  if not vim.g.pr_review_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  -- Check if window is open
  if M._review_window and vim.api.nvim_win_is_valid(M._review_window) then
    -- Close it
    vim.api.nvim_win_close(M._review_window, true)
    M._review_window = nil
  else
    -- Open it
    M.open_review_buffer()
  end
end

-- Setup global navigation keymaps (work during review mode only)
local function setup_global_review_keymaps()
  -- File navigation keymaps (global, but only work in review mode)
  vim.keymap.set("n", M.config.next_file_key, function()
    if vim.g.pr_review_number then
      M.next_file()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(M.config.next_file_key, true, false, true), "n", false)
    end
  end, { desc = "Go to next file (PR review mode)" })

  vim.keymap.set("n", M.config.prev_file_key, function()
    if vim.g.pr_review_number then
      M.prev_file()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(M.config.prev_file_key, true, false, true), "n", false)
    end
  end, { desc = "Go to previous file (PR review mode)" })

  -- Toggle review buffer
  vim.keymap.set("n", M.config.review_buffer.toggle_key, function()
    if vim.g.pr_review_number then
      M.toggle_review_buffer()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(M.config.review_buffer.toggle_key, true, false, true), "n", false)
    end
  end, { desc = "Toggle review buffer (PR review mode)" })
end

update_changes_float = function()
  if not vim.g.pr_review_number then
    close_float_wins()
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = M._buffer_hunks[bufnr]

  if not hunks or #hunks == 0 then
    close_float_wins()
    return
  end

  -- Get file position from review files (use ordered list if available)
  local file_path = get_relative_path(bufnr)
  local file_list = #M._review_files_ordered > 0 and M._review_files_ordered or M._review_files
  local file_idx = 1
  local total_files = #file_list
  local file_status = "M" -- default

  for i, file in ipairs(file_list) do
    if file.path == file_path then
      file_idx = i
      file_status = file.status
      break
    end
  end

  -- Get cursor position for current hunk
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local current_idx = 0
  for i, hunk in ipairs(hunks) do
    if cursor_line >= hunk.start_line then
      current_idx = i
    end
  end
  if current_idx == 0 then
    current_idx = 1
  end

  local comments = M._buffer_comments[bufnr]
  local comment_count = comments and #comments or 0
  local stats = M._buffer_stats[bufnr]
  local is_viewed = M._viewed_files[file_path] or false

  -- FLOAT 1: General info (file x/total)
  local general_lines = {}
  if M.config.show_icons then
    table.insert(general_lines, string.format(" 📁 File %d/%d ", file_idx, total_files))
  else
    table.insert(general_lines, string.format(" File %d/%d ", file_idx, total_files))
  end

  -- FLOAT 2: Buffer info (viewed, hunks, stats, comments)
  local buffer_lines = {}
  if M.config.show_icons then
    local viewed_icon = is_viewed and "✓" or "○"
    table.insert(buffer_lines, string.format(" %s %s ", viewed_icon, is_viewed and "Viewed" or "Not viewed"))
  else
    table.insert(buffer_lines, string.format(" [%s] ", is_viewed and "Viewed" or "Not viewed"))
  end
  table.insert(buffer_lines, string.format(" %d/%d changes ", current_idx, #hunks))
  if stats then
    table.insert(buffer_lines, string.format(" +%d ~%d -%d ", stats.additions, stats.modifications, stats.deletions))
  end
  if comment_count > 0 then
    if M.config.show_icons then
      table.insert(buffer_lines, string.format(" 💬 %d comments ", comment_count))
    else
      table.insert(buffer_lines, string.format(" %d comments ", comment_count))
    end
  end

  -- FLOAT 3: Keymaps
  local keymap_lines = {}
  table.insert(keymap_lines, string.format(" %s: Next hunk ", M.config.next_hunk_key))
  table.insert(keymap_lines, string.format(" %s: Prev hunk ", M.config.prev_hunk_key))
  table.insert(keymap_lines, string.format(" %s: Next file ", M.config.next_file_key))
  table.insert(keymap_lines, string.format(" %s: Prev file ", M.config.prev_file_key))
  table.insert(keymap_lines, string.format(" %s: Mark viewed ", M.config.mark_as_viewed_key))

  -- Helper to create/update float
  local function create_or_update_float(win_var, lines, row_offset, highlight)
    local max_width = 0
    for _, line in ipairs(lines) do
      if #line > max_width then
        max_width = #line
      end
    end

    local buf
    if win_var and vim.api.nvim_win_is_valid(win_var) then
      buf = vim.api.nvim_win_get_buf(win_var)
    else
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    if not win_var or not vim.api.nvim_win_is_valid(win_var) then
      local new_win = vim.api.nvim_open_win(buf, false, {
        relative = "win",
        anchor = "NE",
        width = max_width,
        height = #lines,
        row = row_offset,
        col = vim.api.nvim_win_get_width(0),
        style = "minimal",
        border = "rounded",
        focusable = false,
        zindex = 50,
      })
      vim.api.nvim_set_option_value("winhl", highlight, { win = new_win })
      return new_win
    else
      vim.api.nvim_win_set_config(win_var, {
        relative = "win",
        anchor = "NE",
        width = max_width,
        height = #lines,
        row = row_offset,
        col = vim.api.nvim_win_get_width(0),
      })
      return win_var
    end
  end

  -- Create the 3 floats stacked vertically
  -- Use red border for deleted files
  local border_hl = file_status == "D" and "Normal:DiagnosticError,FloatBorder:DiagnosticError" or "Normal:DiagnosticInfo,FloatBorder:DiagnosticInfo"
  M._float_win_general = create_or_update_float(M._float_win_general, general_lines, 0, border_hl)

  local general_height = #general_lines + 2 -- +2 for border
  local buffer_hl = file_status == "D" and "Normal:DiagnosticError,FloatBorder:DiagnosticError" or "Normal:DiagnosticHint,FloatBorder:DiagnosticHint"
  M._float_win_buffer = create_or_update_float(M._float_win_buffer, buffer_lines, general_height, buffer_hl)

  local buffer_height = #buffer_lines + 2
  local keymap_hl = file_status == "D" and "Normal:DiagnosticError,FloatBorder:DiagnosticError" or "Normal:DiagnosticWarn,FloatBorder:DiagnosticWarn"
  M._float_win_keymaps = create_or_update_float(M._float_win_keymaps, keymap_lines, general_height + buffer_height, keymap_hl)
end

function M.mark_file_as_viewed_and_next()
  if not vim.g.pr_review_number then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local file_path = get_relative_path(bufnr)

  -- Mark current file as viewed
  M._viewed_files[file_path] = true

  -- Save session
  save_session()

  -- Update the float to show new status
  update_changes_float()

  -- Update review buffer
  M.refresh_review_buffer()

  -- Go to next file
  M.next_file()
end

function M.next_hunk()
  if not vim.g.pr_review_number then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = M._buffer_hunks[bufnr]

  if not hunks or #hunks == 0 then
    vim.notify("No hunks in this buffer", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  -- Find the next hunk after the current cursor position
  for _, hunk in ipairs(hunks) do
    if hunk.start_line > current_line then
      vim.api.nvim_win_set_cursor(0, { hunk.start_line, 0 })
      vim.cmd("normal! zz")
      return
    end
  end

  -- If no hunk found after cursor, wrap to first hunk
  vim.api.nvim_win_set_cursor(0, { hunks[1].start_line, 0 })
  vim.cmd("normal! zz")
end

function M.prev_hunk()
  if not vim.g.pr_review_number then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = M._buffer_hunks[bufnr]

  if not hunks or #hunks == 0 then
    vim.notify("No hunks in this buffer", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  -- Find the previous hunk before the current cursor position
  for i = #hunks, 1, -1 do
    local hunk = hunks[i]
    if hunk.start_line < current_line then
      vim.api.nvim_win_set_cursor(0, { hunk.start_line, 0 })
      vim.cmd("normal! zz")
      return
    end
  end

  -- If no hunk found before cursor, wrap to last hunk
  vim.api.nvim_win_set_cursor(0, { hunks[#hunks].start_line, 0 })
  vim.cmd("normal! zz")
end

function M.next_file()
  -- Use ordered list from ReviewBuffer
  local file_list = #M._review_files_ordered > 0 and M._review_files_ordered or M._review_files

  if not vim.g.pr_review_number or #file_list == 0 then
    return
  end

  local current_file = get_relative_path(vim.api.nvim_get_current_buf())
  local current_idx = nil

  for i, file in ipairs(file_list) do
    if file.path == current_file then
      current_idx = i
      break
    end
  end

  if not current_idx then
    -- Open first file
    if file_list[1] then
      open_file_safe(file_list[1], nil)
    end
    return
  end

  if current_idx >= #file_list then
    vim.notify("Already at the last file", vim.log.levels.INFO)
    return
  end

  local next_file = file_list[current_idx + 1]
  open_file_safe(next_file, nil)
end

function M.prev_file()
  -- Use ordered list from ReviewBuffer
  local file_list = #M._review_files_ordered > 0 and M._review_files_ordered or M._review_files

  if not vim.g.pr_review_number or #file_list == 0 then
    return
  end

  local current_file = get_relative_path(vim.api.nvim_get_current_buf())
  local current_idx = nil

  for i, file in ipairs(file_list) do
    if file.path == current_file then
      current_idx = i
      break
    end
  end

  if not current_idx then
    -- Open first file
    if file_list[1] then
      open_file_safe(file_list[1], nil)
    end
    return
  end

  if current_idx <= 1 then
    vim.notify("Already at the first file", vim.log.levels.INFO)
    return
  end

  local prev_file = file_list[current_idx - 1]
  open_file_safe(prev_file, nil)
end

local function load_changes_for_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.g.pr_review_number then
    return
  end

  local file_path = get_relative_path(bufnr)

  -- Find status from review files
  local status = "M" -- default to modified
  for _, file in ipairs(M._review_files) do
    if file.path == file_path then
      status = file.status
      break
    end
  end

  get_changed_lines_for_file(file_path, status, function(lines, hunks)
    if lines and #lines > 0 then
      M._buffer_changes[bufnr] = lines
      M._buffer_hunks[bufnr] = hunks

      vim.api.nvim_buf_clear_namespace(bufnr, changes_ns_id, 0, -1)
      for _, line in ipairs(lines) do
        local line_idx = line - 1
        if line_idx >= 0 and line_idx < vim.api.nvim_buf_line_count(bufnr) then
          vim.api.nvim_buf_set_extmark(bufnr, changes_ns_id, line_idx, 0, {
            sign_text = "│",
            sign_hl_group = "DiffAdd",
          })
        end
      end

      -- Setup buffer-local keymaps for files with changes (only once per buffer)
      if not M._buffer_keymaps_saved[bufnr] then
        vim.keymap.set("n", M.config.next_hunk_key, M.next_hunk, { buffer = bufnr, desc = "Jump to next hunk" })
        vim.keymap.set("n", M.config.prev_hunk_key, M.prev_hunk, { buffer = bufnr, desc = "Jump to previous hunk" })
        vim.keymap.set("n", M.config.mark_as_viewed_key, M.mark_file_as_viewed_and_next, { buffer = bufnr, desc = "Mark as viewed and next" })
        M._buffer_keymaps_saved[bufnr] = true
      end

      if bufnr == vim.api.nvim_get_current_buf() then
        update_changes_float()
      end
    else
      M._buffer_changes[bufnr] = nil
      M._buffer_hunks[bufnr] = nil
      close_float_wins()
    end
  end)
end

local function count_comments_at_line(comments, line)
  local count = 0
  for _, comment in ipairs(comments) do
    if comment.line == line then
      count = count + 1
    end
  end
  return count
end

local function display_comments(bufnr, comments)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local lines_with_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line and comment.line > 0 then
      lines_with_comments[comment.line] = true
    end
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for line, _ in pairs(lines_with_comments) do
    local line_idx = line - 1
    if line_idx < line_count then
      local count = count_comments_at_line(comments, line)
      local text
      if M.config.show_icons then
        text = count > 1 and string.format(" 💬 %d comments", count) or " 💬 1 comment"
      else
        text = count > 1 and string.format(" [%d comments]", count) or " [1 comment]"
      end

      vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_idx, 0, {
        virt_text = { { text, "DiagnosticInfo" } },
        virt_text_pos = "eol",
      })
    end
  end
end

function M.show_comments_at_cursor()
  if not vim.g.pr_review_number then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local line_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line == cursor_line then
      table.insert(line_comments, comment)
    end
  end

  if #line_comments == 0 then
    return
  end

  local lines = {}
  for i, comment in ipairs(line_comments) do
    if i > 1 then
      table.insert(lines, string.rep("─", 40))
    end
    if M.config.show_icons then
      table.insert(lines, string.format("👤 %s", comment.user))
    else
      table.insert(lines, string.format("@%s", comment.user))
    end
    table.insert(lines, "")
    for body_line in comment.body:gmatch("[^\r\n]+") do
      table.insert(lines, body_line)
    end
  end

  vim.lsp.util.open_floating_preview(lines, "markdown", {
    border = "rounded",
    focus_id = "pr_review_comment",
    max_width = 80,
    max_height = 20,
  })
end

function M.load_comments_for_buffer(bufnr, force_reload)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not M.config.show_comments then
    return
  end

  local pr_number = vim.g.pr_review_number
  if not pr_number then
    return
  end

  if force_reload then
    github.clear_cache()
  end

  local file_path = get_relative_path(bufnr)

  github.get_comments_for_file(pr_number, file_path, function(comments, err)
    if err then
      return
    end

    if comments and #comments > 0 then
      M._buffer_comments[bufnr] = comments
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          display_comments(bufnr, comments)
        end
      end)
    else
      M._buffer_comments[bufnr] = nil
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
        end
      end)
    end
  end)
end

local function input_multiline(prompt, callback)
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. prompt .. " (save: <C-s>, cancel: <Esc>) ",
    title_pos = "center",
  })

  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")
    callback(nil)
  end, { buffer = buf })

  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    vim.api.nvim_win_close(win, true)
    vim.cmd("stopinsert")
    if text ~= "" then
      callback(text)
    else
      callback(nil)
    end
  end, { buffer = buf })

  -- Enter insert mode automatically
  vim.cmd("startinsert")
end

function M.approve_pr()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  input_multiline("Approval comment (optional)", function(body)
    vim.notify("Approving PR #" .. pr_number .. "...", vim.log.levels.INFO)
    github.approve_pr(pr_number, body, function(ok, err)
      if ok then
        vim.notify("✅ PR #" .. pr_number .. " approved!", vim.log.levels.INFO)
      else
        vim.notify("❌ Failed to approve: " .. (err or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.request_changes()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  input_multiline("Reason for requesting changes", function(body)
    if not body then
      vim.notify("Reason is required", vim.log.levels.WARN)
      return
    end
    vim.notify("Requesting changes on PR #" .. pr_number .. "...", vim.log.levels.INFO)
    github.request_changes(pr_number, body, function(ok, err)
      if ok then
        vim.notify("✅ Requested changes on PR #" .. pr_number, vim.log.levels.INFO)
      else
        vim.notify("❌ Failed to request changes: " .. (err or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.add_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  input_multiline("PR Comment", function(body)
    if not body then
      return
    end
    vim.notify("Adding comment...", vim.log.levels.INFO)
    github.add_pr_comment(pr_number, body, function(ok, err)
      if ok then
        vim.notify("✅ Comment added to PR #" .. pr_number, vim.log.levels.INFO)
      else
        vim.notify("❌ Failed to add comment: " .. (err or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.add_review_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local file_path = get_relative_path(bufnr)

  input_multiline("Review comment for line " .. cursor_line, function(body)
    if not body then
      return
    end
    vim.notify("Adding review comment...", vim.log.levels.INFO)
    github.add_review_comment(pr_number, file_path, cursor_line, body, function(ok, err)
      if ok then
        vim.notify("✅ Review comment added", vim.log.levels.INFO)
        M.load_comments_for_buffer(bufnr, true)
      else
        vim.notify("❌ Failed to add review comment: " .. (err or "unknown"), vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.reply_to_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    vim.notify("No comments in this file", vim.log.levels.WARN)
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local line_comments = {}
  for _, comment in ipairs(comments) do
    if comment.line == cursor_line then
      table.insert(line_comments, comment)
    end
  end

  if #line_comments == 0 then
    vim.notify("No comments on this line", vim.log.levels.WARN)
    return
  end

  local function do_reply(comment)
    input_multiline("Reply to " .. comment.user, function(body)
      if not body then
        return
      end
      vim.notify("Sending reply...", vim.log.levels.INFO)
      github.reply_to_comment(pr_number, comment.id, body, function(ok, err)
        if ok then
          vim.notify("✅ Reply added", vim.log.levels.INFO)
          M.load_comments_for_buffer(bufnr, true)
        else
          vim.notify("❌ Failed to reply: " .. (err or "unknown"), vim.log.levels.ERROR)
        end
      end)
    end)
  end

  if #line_comments == 1 then
    do_reply(line_comments[1])
  else
    local items = {}
    for _, c in ipairs(line_comments) do
      table.insert(items, string.format("[%s]: %s", c.user, c.body:sub(1, 50)))
    end
    vim.ui.select(items, { prompt = "Select comment to reply:" }, function(_, idx)
      if idx then
        do_reply(line_comments[idx])
      end
    end)
  end
end

function M.edit_my_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    vim.notify("No comments in this file", vim.log.levels.WARN)
    return
  end

  github.get_current_user(function(current_user, err)
    if err or not current_user then
      vim.notify("Failed to get current user", vim.log.levels.ERROR)
      return
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local my_comments = {}
    for _, comment in ipairs(comments) do
      if comment.line == cursor_line and comment.user == current_user then
        table.insert(my_comments, comment)
      end
    end

    if #my_comments == 0 then
      vim.notify("No comments from you on this line", vim.log.levels.WARN)
      return
    end

    local function do_edit(comment)
      local buf = vim.api.nvim_create_buf(false, true)
      local width = math.floor(vim.o.columns * 0.6)
      local height = math.floor(vim.o.lines * 0.4)

      local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2),
        style = "minimal",
        border = "rounded",
        title = " Edit comment (save: <C-s>, cancel: <Esc>) ",
        title_pos = "center",
      })

      local lines = {}
      for line in comment.body:gmatch("[^\r\n]+") do
        table.insert(lines, line)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      vim.bo[buf].filetype = "markdown"
      vim.bo[buf].bufhidden = "wipe"

      vim.keymap.set("n", "<Esc>", function()
        vim.api.nvim_win_close(win, true)
        vim.cmd("stopinsert")
      end, { buffer = buf })

      vim.keymap.set({ "n", "i" }, "<C-s>", function()
        local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local text = table.concat(new_lines, "\n")
        vim.api.nvim_win_close(win, true)
        vim.cmd("stopinsert")
        if text ~= "" then
          vim.notify("Updating comment...", vim.log.levels.INFO)
          github.edit_comment(pr_number, comment.id, text, function(ok, edit_err)
            if ok then
              vim.notify("✅ Comment updated", vim.log.levels.INFO)
              M.load_comments_for_buffer(bufnr, true)
            else
              vim.notify("❌ Failed to edit: " .. (edit_err or "unknown"), vim.log.levels.ERROR)
            end
          end)
        end
      end, { buffer = buf })

      -- Enter insert mode automatically
      vim.cmd("startinsert")
    end

    if #my_comments == 1 then
      do_edit(my_comments[1])
    else
      local items = {}
      for _, c in ipairs(my_comments) do
        table.insert(items, c.body:sub(1, 50))
      end
      vim.ui.select(items, { prompt = "Select comment to edit:" }, function(_, idx)
        if idx then
          do_edit(my_comments[idx])
        end
      end)
    end
  end)
end

function M.delete_my_comment()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local comments = M._buffer_comments[bufnr]
  if not comments or #comments == 0 then
    vim.notify("No comments in this file", vim.log.levels.WARN)
    return
  end

  github.get_current_user(function(current_user, err)
    if err or not current_user then
      vim.notify("Failed to get current user", vim.log.levels.ERROR)
      return
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local my_comments = {}
    for _, comment in ipairs(comments) do
      if comment.line == cursor_line and comment.user == current_user then
        table.insert(my_comments, comment)
      end
    end

    if #my_comments == 0 then
      vim.notify("No comments from you on this line", vim.log.levels.WARN)
      return
    end

    local function do_delete(comment)
      vim.ui.select({ "Yes", "No" }, { prompt = "Delete this comment?" }, function(choice)
        if choice == "Yes" then
          vim.notify("Deleting comment...", vim.log.levels.INFO)
          github.delete_comment(pr_number, comment.id, function(ok, del_err)
            if ok then
              vim.notify("✅ Comment deleted", vim.log.levels.INFO)
              M.load_comments_for_buffer(bufnr, true)
            else
              vim.notify("❌ Failed to delete: " .. (del_err or "unknown"), vim.log.levels.ERROR)
            end
          end)
        end
      end)
    end

    if #my_comments == 1 then
      do_delete(my_comments[1])
    else
      local items = {}
      for _, c in ipairs(my_comments) do
        table.insert(items, c.body:sub(1, 50))
      end
      vim.ui.select(items, { prompt = "Select comment to delete:" }, function(_, idx)
        if idx then
          do_delete(my_comments[idx])
        end
      end)
    end
  end)
end

function M.load_last_session()
  if vim.g.pr_review_number then
    vim.notify("Already in review mode. Use :PRReviewCleanup first.", vim.log.levels.WARN)
    return
  end

  local session_data = load_session()
  if not session_data then
    vim.notify("No saved session found for this project", vim.log.levels.INFO)
    return
  end

  -- Verify we're in the same directory
  if session_data.cwd ~= vim.fn.getcwd() then
    vim.notify("Session is for a different directory: " .. session_data.cwd, vim.log.levels.WARN)
    return
  end

  vim.notify("Loading review session for PR #" .. session_data.pr_number .. "...", vim.log.levels.INFO)

  -- Restore global state
  vim.g.pr_review_number = session_data.pr_number
  vim.g.pr_review_previous_branch = session_data.previous_branch
  vim.g.pr_review_modified_files = session_data.modified_files
  M._viewed_files = session_data.viewed_files or {}

  -- Open review buffer and first file
  M.open_review_buffer(function()
    if M._review_files[1] then
      vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/" .. M._review_files[1].path))
    end
  end)

  vim.notify("✅ Session restored for PR #" .. session_data.pr_number, vim.log.levels.INFO)
end

function M.show_pr_info()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  github.get_pr_info(pr_number, function(info, err)
    if err then
      vim.notify("Failed to get PR info: " .. err, vim.log.levels.ERROR)
      return
    end

    local review_status = info.review_decision or "PENDING"
    local review_icon, approved_icon, changes_icon, comment_icon, mergeable_icon
    local author_prefix, branch_prefix, files_prefix, add_prefix, del_prefix

    if M.config.show_icons then
      review_icon = "⏳"
      if review_status == "APPROVED" then
        review_icon = "✅"
      elseif review_status == "CHANGES_REQUESTED" then
        review_icon = "❌"
      elseif review_status == "REVIEW_REQUIRED" then
        review_icon = "👀"
      end

      mergeable_icon = "❓"
      if info.mergeable == "MERGEABLE" then
        mergeable_icon = "✅"
      elseif info.mergeable == "CONFLICTING" then
        mergeable_icon = "⚠️"
      end

      approved_icon = "✅"
      changes_icon = "❌"
      comment_icon = "💬"
      author_prefix = "👤 Author:"
      branch_prefix = "🌿"
      files_prefix = "📁 Files changed:"
      add_prefix = "➕ Additions:"
      del_prefix = "➖ Deletions:"
    else
      review_icon = "[PENDING]"
      if review_status == "APPROVED" then
        review_icon = "[APPROVED]"
      elseif review_status == "CHANGES_REQUESTED" then
        review_icon = "[CHANGES]"
      elseif review_status == "REVIEW_REQUIRED" then
        review_icon = "[REVIEW]"
      end

      mergeable_icon = "[?]"
      if info.mergeable == "MERGEABLE" then
        mergeable_icon = "[OK]"
      elseif info.mergeable == "CONFLICTING" then
        mergeable_icon = "[CONFLICT]"
      end

      approved_icon = "[+]"
      changes_icon = "[-]"
      comment_icon = ""
      author_prefix = "Author:"
      branch_prefix = ""
      files_prefix = "Files changed:"
      add_prefix = "Additions:"
      del_prefix = "Deletions:"
    end

    local approved_by = ""
    if info.reviewers and #info.reviewers.approved > 0 then
      approved_by = " (" .. table.concat(info.reviewers.approved, ", ") .. ")"
    end

    local changes_by = ""
    if info.reviewers and #info.reviewers.changes_requested > 0 then
      changes_by = " (" .. table.concat(info.reviewers.changes_requested, ", ") .. ")"
    end

    local lines = {
      string.format("# PR #%d", info.number),
      "",
      string.format("**%s**", info.title),
      "",
      string.format("%s %s", author_prefix, info.author),
      string.format("%s %s → %s", branch_prefix, info.head_branch, info.base_branch),
      "",
      "## Stats",
      string.format("%s %d", files_prefix, info.changed_files),
      string.format("%s %d", add_prefix, info.additions),
      string.format("%s %d", del_prefix, info.deletions),
      "",
      "## Reviews",
      string.format("%s Status: %s", review_icon, review_status:gsub("_", " ")),
      string.format("%s Approved: %d%s", approved_icon, info.reviews.approved, approved_by),
      string.format("%s Changes requested: %d%s", changes_icon, info.reviews.changes_requested, changes_by),
      string.format("%s Commented: %d", comment_icon, info.reviews.commented),
      "",
      "## Status",
      string.format("%s Mergeable: %s", mergeable_icon, info.mergeable or "UNKNOWN"),
      string.format("%s Comments: %d", comment_icon, info.comments_count),
    }

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false

    local width = 50
    local height = #lines
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      col = math.floor((vim.o.columns - width) / 2),
      row = math.floor((vim.o.lines - height) / 2),
      style = "minimal",
      border = "rounded",
      title = " PR Info ",
      title_pos = "center",
    })

    vim.keymap.set("n", "q", function()
      vim.api.nvim_win_close(win, true)
    end, { buffer = buf })

    vim.keymap.set("n", "<Esc>", function()
      vim.api.nvim_win_close(win, true)
    end, { buffer = buf })
  end)
end

function M.open_pr()
  local pr_number = vim.g.pr_review_number
  if not pr_number then
    vim.notify("Not in review mode", vim.log.levels.WARN)
    return
  end

  local cmd = string.format("gh pr view %d --web", pr_number)
  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("Failed to open PR in browser", vim.log.levels.ERROR)
        end)
      end
    end,
  })
end

function M.list_review_requests()
  if git.has_uncommitted_changes() then
    vim.notify("Cannot start review: you have uncommitted changes. Please commit or stash them first.", vim.log.levels.ERROR)
    return
  end

  vim.notify("Fetching review requests...", vim.log.levels.INFO)

  github.list_review_requests(function(prs, err)
    if err then
      vim.notify("Error fetching review requests: " .. err, vim.log.levels.ERROR)
      return
    end

    if not prs or #prs == 0 then
      vim.notify("No review requests found", vim.log.levels.INFO)
      return
    end

    vim.notify("Found " .. #prs .. " review request(s)", vim.log.levels.INFO)

    local function on_select(pr)
      if not pr then
        return
      end
      M._start_review_for_pr(pr)
    end

    local function on_mark_viewed(pr)
      if not pr then
        return
      end
      vim.notify("Marking PR #" .. pr.number .. " as viewed...", vim.log.levels.INFO)
      github.mark_pr_as_viewed(pr.number, function(ok, mark_err)
        if ok then
          vim.notify("✅ PR #" .. pr.number .. " marked as viewed", vim.log.levels.INFO)
        else
          vim.notify("❌ Failed to mark as viewed: " .. (mark_err or "unknown"), vim.log.levels.ERROR)
        end
      end)
    end

    ui.select_review_request(prs, M.config.picker, M.config.show_icons, on_select, on_mark_viewed)
  end)
end

function M._start_review_for_pr(pr)
  local current_branch = git.get_current_branch()
  if current_branch then
    vim.g.pr_review_previous_branch = current_branch
  end

  local review_branch = string.format(
    "%s%s_to_%s",
    M.config.branch_prefix,
    pr.head_branch,
    pr.base_branch
  )

  vim.notify("Starting review for PR #" .. pr.number .. "...", vim.log.levels.INFO)

  git.fetch_all(function(fetch_ok, fetch_err)
    if not fetch_ok then
      vim.notify("Error fetching: " .. (fetch_err or "unknown"), vim.log.levels.ERROR)
      return
    end

    git.create_review_branch(review_branch, pr.base_branch, function(ok, create_err)
      if not ok then
        vim.notify("Error creating branch: " .. (create_err or "unknown"), vim.log.levels.ERROR)
        return
      end

      git.soft_merge(pr.head_branch, function(merge_ok, merge_err)
        if not merge_ok then
          vim.notify("Error during soft merge: " .. (merge_err or "unknown"), vim.log.levels.ERROR)
          return
        end

        vim.g.pr_review_number = pr.number

        vim.notify(
          string.format("✅ Ready to review PR #%s: %s", pr.number, pr.title),
          vim.log.levels.INFO
        )

        git.get_modified_files_with_lines(function(files, hunks)
          if files and #files > 0 then
            vim.g.pr_review_modified_files = vim.tbl_map(function(f)
              return { path = f.path, status = f.status }
            end, files)

            -- Save initial session
            save_session()

            -- Open review buffer and first file
            M.open_review_buffer(function()
              if M.config.open_files_on_review and M._review_files[1] then
                vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/" .. M._review_files[1].path))
              end
            end)
          end
        end)
      end)
    end)
  end)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  vim.api.nvim_create_user_command("PRReview", function()
    M.review_pr()
  end, { desc = "Select and review a GitHub PR" })

  vim.api.nvim_create_user_command("PRReviewCleanup", function()
    M.cleanup_review_branch()
  end, { desc = "Cleanup review branch and return to previous branch" })

  vim.api.nvim_create_user_command("PRInfo", function()
    M.show_pr_info()
  end, { desc = "Show PR information" })

  vim.api.nvim_create_user_command("PRReviewComment", function()
    M.show_comments_at_cursor()
  end, { desc = "Show PR comments at cursor line" })

  vim.api.nvim_create_user_command("PRApprove", function()
    M.approve_pr()
  end, { desc = "Approve the current PR" })

  vim.api.nvim_create_user_command("PRRequestChanges", function()
    M.request_changes()
  end, { desc = "Request changes on the current PR" })

  vim.api.nvim_create_user_command("PRComment", function()
    M.add_comment()
  end, { desc = "Add a general comment to the PR" })

  vim.api.nvim_create_user_command("PRLineComment", function()
    M.add_review_comment()
  end, { desc = "Add a review comment on the current line" })

  vim.api.nvim_create_user_command("PRReply", function()
    M.reply_to_comment()
  end, { desc = "Reply to a comment on the current line" })

  vim.api.nvim_create_user_command("PREditComment", function()
    M.edit_my_comment()
  end, { desc = "Edit your comment on the current line" })

  vim.api.nvim_create_user_command("PRDeleteComment", function()
    M.delete_my_comment()
  end, { desc = "Delete your comment on the current line" })

  vim.api.nvim_create_user_command("PRListReviewRequests", function()
    M.list_review_requests()
  end, { desc = "List PRs where you are requested as reviewer" })

  vim.api.nvim_create_user_command("PROpen", function()
    M.open_pr()
  end, { desc = "Open PR in browser" })

  vim.api.nvim_create_user_command("PRLoadLastSession", function()
    M.load_last_session()
  end, { desc = "Load last PR review session" })

  vim.api.nvim_create_user_command("PRReviewBuffer", function()
    M.open_review_buffer()
  end, { desc = "Open PR review buffer" })

  -- Setup global navigation keymaps
  setup_global_review_keymaps()

  local augroup = vim.api.nvim_create_augroup("PRReviewComments", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(args)
      if vim.g.pr_review_number then
        M.load_comments_for_buffer(args.buf)
        load_changes_for_buffer(args.buf)
        load_inline_diff_for_buffer(args.buf)

        -- Update review buffer to highlight current file
        M.refresh_review_buffer()

        -- Jump to first change if we haven't already for this buffer
        -- Note: keymaps are now set in load_changes_for_buffer callback, only for files with changes
        if not M._buffer_jumped[args.buf] then
          vim.defer_fn(function()
            local hunks = M._buffer_hunks[args.buf]
            if hunks and #hunks > 0 and vim.api.nvim_get_current_buf() == args.buf then
              vim.api.nvim_win_set_cursor(0, { hunks[1].start_line, 0 })
              vim.cmd("normal! zz")
              M._buffer_jumped[args.buf] = true
            end
          end, 100)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorHold", {
    group = augroup,
    callback = function()
      if vim.g.pr_review_number then
        M.show_comments_at_cursor()
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    callback = function()
      if vim.g.pr_review_number then
        update_changes_float()
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinLeave", {
    group = augroup,
    callback = function()
      close_float_wins()
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(args)
      -- Clean up tracking when buffer is deleted
      M._buffer_keymaps_saved[args.buf] = nil
      M._buffer_jumped[args.buf] = nil
      M._buffer_comments[args.buf] = nil
      M._buffer_changes[args.buf] = nil
      M._buffer_hunks[args.buf] = nil
      M._buffer_stats[args.buf] = nil
    end,
  })

  -- Note: Keymaps are now set as buffer-local in the BufEnter autocmd
  -- This ensures they only work during review mode and don't conflict with existing keymaps
end

function M.review_pr()
  if git.has_uncommitted_changes() then
    vim.notify("Cannot start review: you have uncommitted changes. Please commit or stash them first.", vim.log.levels.ERROR)
    return
  end

  local prs, err = github.list_open_prs()
  if err then
    vim.notify("Error fetching PRs: " .. err, vim.log.levels.ERROR)
    return
  end

  if #prs == 0 then
    vim.notify("No open PRs found", vim.log.levels.INFO)
    return
  end

  ui.select_pr(prs, M.config.picker, function(pr)
    if not pr then
      return
    end

    local current_branch = git.get_current_branch()
    if current_branch then
      vim.g.pr_review_previous_branch = current_branch
    end

    local review_branch = string.format(
      "%s%s_to_%s",
      M.config.branch_prefix,
      pr.head_branch,
      pr.base_branch
    )

    git.fetch_all(function(fetch_ok, fetch_err)
      if not fetch_ok then
        vim.notify("Error fetching: " .. (fetch_err or "unknown"), vim.log.levels.ERROR)
        return
      end

      git.create_review_branch(review_branch, pr.base_branch, function(ok, create_err)
        if not ok then
          vim.notify("Error creating branch: " .. (create_err or "unknown"), vim.log.levels.ERROR)
          return
        end

        git.soft_merge(pr.head_branch, function(merge_ok, merge_err)
          if not merge_ok then
            vim.notify("Error during soft merge: " .. (merge_err or "unknown"), vim.log.levels.ERROR)
            return
          end

          vim.g.pr_review_number = pr.number

          vim.notify(
            string.format("✅ Ready to review PR #%s: %s", pr.number, pr.title),
            vim.log.levels.INFO
          )

          git.get_modified_files_with_lines(function(files)
            if files and #files > 0 then
              vim.g.pr_review_modified_files = vim.tbl_map(function(f)
                return { path = f.path, status = f.status }
              end, files)

              -- Save initial session
              save_session()

              -- Open review buffer and first file
              M.open_review_buffer(function()
                if M.config.open_files_on_review and M._review_files[1] then
                  vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/" .. M._review_files[1].path))
                end
              end)
            end
          end)
        end)
      end)
    end)
  end)
end

function M.cleanup_review_branch()
  local current = git.get_current_branch()
  if not current or not current:match("^" .. M.config.branch_prefix) then
    vim.notify("Not on a review branch", vim.log.levels.WARN)
    return
  end

  local target = vim.g.pr_review_previous_branch or "master"

  git.cleanup_review(current, target, function(ok, err)
    if ok then
      delete_session()
      vim.g.pr_review_number = nil
      github.clear_cache()
      M._buffer_comments = {}
      M._buffer_changes = {}
      M._buffer_hunks = {}
      M._buffer_stats = {}
      M._viewed_files = {}
      M._buffer_jumped = {}
      M._buffer_keymaps_saved = {}
      M._review_files = {}
      M._review_files_ordered = {}
      M._review_filter = "all"
      if M._review_window and vim.api.nvim_win_is_valid(M._review_window) then
        vim.api.nvim_win_close(M._review_window, true)
      end
      M._review_window = nil
      M._review_buffer = nil
      close_float_wins()

      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
          vim.api.nvim_buf_clear_namespace(buf, changes_ns_id, 0, -1)
          vim.api.nvim_buf_clear_namespace(buf, diff_ns_id, 0, -1)
          -- Delete buffer-local keymaps
          pcall(vim.keymap.del, "n", M.config.next_hunk_key, { buffer = buf })
          pcall(vim.keymap.del, "n", M.config.prev_hunk_key, { buffer = buf })
          pcall(vim.keymap.del, "n", M.config.mark_as_viewed_key, { buffer = buf })
        end
      end

      vim.notify("Cleaned up review branch, back on: " .. target, vim.log.levels.INFO)
    else
      vim.notify("Error cleaning up: " .. (err or "unknown"), vim.log.levels.ERROR)
    end
  end)
end

return M
