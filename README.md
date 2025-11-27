# PR Reviewer for Neovim

A lightweight Neovim plugin for reviewing GitHub Pull Requests directly in your editor. Check out PR changes, view comments, add reviews, and approve/reject PRs without leaving Neovim.

## Features

- **Review PRs locally** - Checkout PR changes as unstaged modifications
- **View PR comments** - See review comments inline with virtual text
- **Add comments** - Add review comments, reply to existing ones, edit or delete your comments
- **Approve/Reject PRs** - Submit reviews directly from Neovim
- **PR Info** - View PR stats, review status, and merge status
- **Quickfix integration** - Navigate modified files with `:cnext`/`:cprev`
- **Change tracking** - See your progress through changes with a floating indicator
- **Multiple pickers** - Native `vim.ui.select`, Telescope, or fzf-lua

## Requirements

- Neovim >= 0.9.0
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- Git

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "your-username/pr-reviewer.nvim",
  config = function()
    require("pr-reviewer").setup({
      -- options (see Configuration below)
    })
  end,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "your-username/pr-reviewer.nvim",
  config = function()
    require("pr-reviewer").setup()
  end
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'your-username/pr-reviewer.nvim'

" In your init.vim or init.lua
lua require("pr-reviewer").setup()
```

## Configuration

```lua
require("pr-reviewer").setup({
  -- Prefix for review branches (default: "reviewing_")
  branch_prefix = "reviewing_",

  -- Picker for PR selection: "native", "fzf-lua", or "telescope"
  picker = "native",

  -- Open modified files in quickfix after starting review
  open_files_on_review = true,

  -- Show PR comments as virtual text in buffers
  show_comments = true,

  -- Show icons/emojis in UI (set to false for a text-only interface)
  show_icons = true,

  -- Show inline diff in buffers (old lines as virtual text above changes)
  show_inline_diff = true,

  -- Key to mark file as viewed and go to next file (only works in review mode)
  mark_as_viewed_key = "<CR>",

  -- Key to jump to next hunk (only works in review mode)
  next_hunk_key = "<C-j>",

  -- Key to jump to previous hunk (only works in review mode)
  prev_hunk_key = "<C-k>",

  -- Key to go to next file in quickfix (only works in review mode)
  next_file_key = "<C-l>",

  -- Key to go to previous file in quickfix (only works in review mode)
  prev_file_key = "<C-h>",
})
```

## Commands

### Review Workflow

| Command | Description |
|---------|-------------|
| `:PRReview` | Select and start reviewing a PR |
| `:PRListReviewRequests` | List PRs where you are requested as reviewer |
| `:PRReviewCleanup` | End review, clean up changes, return to previous branch |
| `:PRInfo` | Show PR information (stats, reviews, merge status) |
| `:PROpen` | Open PR in browser |
| `:PRLoadLastSession` | Restore last PR review session (after restarting Neovim) |

### Comments

| Command | Description |
|---------|-------------|
| `:PRReviewComment` | Show comments at cursor line (also shows on `CursorHold`) |
| `:PRLineComment` | Add a review comment on the current line |
| `:PRReply` | Reply to a comment on the current line |
| `:PREditComment` | Edit your comment on the current line |
| `:PRDeleteComment` | Delete your comment on the current line |
| `:PRComment` | Add a general comment to the PR |

### Review Actions

| Command | Description |
|---------|-------------|
| `:PRApprove` | Approve the PR (with optional comment) |
| `:PRRequestChanges` | Request changes on the PR (requires reason) |

## Usage Guide

### Starting a Review

1. Make sure you have no uncommitted changes (the plugin will warn you)
2. Run `:PRReview` to see a list of open PRs
3. Select a PR to review
4. The plugin will:
   - Save your current branch
   - Create a review branch
   - Soft-merge the PR changes (unstaged)
   - Open the quickfix list with all modified files (if `open_files_on_review = true`)

### Review Requests

Use `:PRListReviewRequests` to see PRs where you've been requested as a reviewer:

- Shows PR info with additions/deletions stats
- **Enter**: Start reviewing the selected PR
- **Ctrl-v** (fzf-lua/telescope): Mark PR as viewed without starting review

The fzf-lua picker shows a hint header with available actions.

### Navigating Changes

The plugin includes built-in navigation that only works during PR review mode:

**Hunk Navigation** (within a file):
- `<C-j>` (default) - Jump to next hunk
- `<C-k>` (default) - Jump to previous hunk

**File Navigation** (between modified files):
- `<C-l>` (default) - Go to next file in quickfix
- `<C-h>` (default) - Go to previous file in quickfix

All keybindings are configurable in setup and only activate during PR review mode (won't interfere with normal usage).

You can also use the quickfix list commands:

- `:cnext` or `]q` - Go to next modified file
- `:cprev` or `[q` - Go to previous modified file
- `:copen` - Open the quickfix window
- `:cclose` - Close the quickfix window

### Change Progress Indicator

When reviewing a file with changes, you'll see a floating indicator in the top-right corner showing:

```
┌──────────────────────────┐
│ ✓ Viewed                 │
│ 2/5 changes              │
│ +15 ~3 -8                │
│ 💬 2 comments            │
│ <CR>: Mark as viewed     │
└──────────────────────────┘
```

- **Viewed status**: Shows if the current file has been marked as viewed
- **Change progress**: Current change position (groups consecutive changed lines together)
- **Stats**: +additions ~modifications -deletions
- **Comments**: Number of PR comments in this file
- **Mark as viewed**: Press the configured key (default `<CR>`) to mark the file as viewed and jump to the next file in the quickfix list

**Note**: The mark as viewed key only works during PR review mode and won't interfere with normal usage.

### Session Persistence

The plugin automatically saves your review session state, allowing you to resume where you left off after restarting Neovim:

- **Auto-save**: Session is saved when you start a review and whenever you mark files as viewed
- **Per-project**: Each project directory gets its own session file
- **What's saved**: PR number, previous branch, modified files list, and viewed files status
- **Auto-cleanup**: Session file is deleted when you run `:PRReviewCleanup`

To restore a session after restarting Neovim:

```vim
:PRLoadLastSession
```

This will:
- Restore the PR review state
- Re-populate the quickfix list with modified files
- Restore your viewed files status
- Continue from where you left off

Session files are stored in `~/.local/share/nvim/pr-reviewer-sessions/` (or equivalent on your platform).

### Inline Diff View

When `show_inline_diff` is enabled, the plugin displays the diff directly in your buffer:

- **Removed lines** appear as virtual text above the changed section (highlighted with `DiffDelete`)
- **Added/modified lines** are highlighted with `DiffAdd` and marked with a `+` sign
- This works **without gitsigns**, using native Neovim extmarks

Example visualization:
```
  - old line that was removed
  - another old line
+ new line that replaced them
+ another new line
```

Set `show_inline_diff = false` if you prefer to use gitsigns or another diff tool.

### Viewing and Adding Comments

- **View comments**: Hover on a line with comments (or use `:PRReviewComment`)
- **Add comment**: Position cursor on a line and run `:PRLineComment`
- **Reply**: Position cursor on a line with comments and run `:PRReply`
- **Edit/Delete**: Use `:PREditComment` or `:PRDeleteComment` on your own comments

Comment editor uses `<C-s>` to save and `<Esc>` to cancel.

### Finishing the Review

1. Run `:PRApprove` to approve, or `:PRRequestChanges` to request changes
2. Run `:PRReviewCleanup` to:
   - Revert all PR changes
   - Delete the review branch
   - Return to your original branch
   - Close the quickfix window

## Complete Workflow Example

Here's a complete workflow for reviewing a PR:

```vim
" 1. Start reviewing a PR
:PRReview
" Select PR #42 from the list

" 2. Navigate through modified files using quickfix
:cnext          " Go to next file
:cprev          " Go to previous file

" 3. Navigate through changes within a file (with gitsigns)
]h              " Jump to next hunk
[h              " Jump to previous hunk

" 4. View PR info to check current status
:PRInfo

" 5. Add a comment on a specific line
:PRLineComment
" Type your comment, press <C-s> to save

" 6. Reply to an existing comment
:PRReply
" Type your reply, press <C-s> to save

" 7. Approve the PR when satisfied
:PRApprove
" Optionally add an approval message, press <C-s> to submit

" 8. Clean up and return to your work
:PRReviewCleanup
```

## Recommended Keymaps

```lua
local pr = require("pr-reviewer")

-- Review workflow
vim.keymap.set("n", "<leader>pr", ":PRReview<CR>", { desc = "Start PR review" })
vim.keymap.set("n", "<leader>pl", ":PRListReviewRequests<CR>", { desc = "List review requests" })
vim.keymap.set("n", "<leader>pc", ":PRReviewCleanup<CR>", { desc = "Cleanup PR review" })
vim.keymap.set("n", "<leader>pi", ":PRInfo<CR>", { desc = "Show PR info" })
vim.keymap.set("n", "<leader>po", ":PROpen<CR>", { desc = "Open PR in browser" })

-- Comments
vim.keymap.set("n", "<leader>pC", ":PRLineComment<CR>", { desc = "Add line comment" })
vim.keymap.set("n", "<leader>pR", ":PRReply<CR>", { desc = "Reply to comment" })
vim.keymap.set("n", "<leader>pe", ":PREditComment<CR>", { desc = "Edit my comment" })
vim.keymap.set("n", "<leader>pd", ":PRDeleteComment<CR>", { desc = "Delete my comment" })

-- Review actions
vim.keymap.set("n", "<leader>pa", ":PRApprove<CR>", { desc = "Approve PR" })
vim.keymap.set("n", "<leader>px", ":PRRequestChanges<CR>", { desc = "Request changes" })

-- Quickfix navigation (if not already mapped)
vim.keymap.set("n", "]q", ":cnext<CR>", { desc = "Next quickfix" })
vim.keymap.set("n", "[q", ":cprev<CR>", { desc = "Previous quickfix" })
```

## Integration with Other Plugins

### gitsigns.nvim (Optional)

**gitsigns.nvim is optional** - the plugin now has built-in inline diff visualization. However, gitsigns can still be useful for:

- Hunk navigation with `]h` and `[h`
- Interactive hunk staging/unstaging
- Additional git blame and diff features

If you prefer to use gitsigns instead of the built-in inline diff, set `show_inline_diff = false`:

```lua
require("pr-reviewer").setup({
  show_inline_diff = false,  -- Disable built-in diff, use gitsigns instead
})

require("gitsigns").setup({
  -- your gitsigns config
})

-- Navigation keymaps
vim.keymap.set("n", "]h", function() require("gitsigns").next_hunk() end)
vim.keymap.set("n", "[h", function() require("gitsigns").prev_hunk() end)
```

### Telescope / fzf-lua

Set your preferred picker in the config:

```lua
require("pr-reviewer").setup({
  picker = "telescope",  -- or "fzf-lua"
})
```

## How It Works

1. **Starting review**: Creates a branch from the PR's base branch, then soft-merges the PR's head branch without committing. This leaves all PR changes as unstaged modifications.

2. **Comments**: Fetches PR comments via GitHub API and displays them as virtual text. Comments are cached for performance.

3. **Change tracking**: Parses `git diff` output to identify changed lines and groups consecutive lines into "hunks" for the progress indicator.

4. **Cleanup**: Reverts only the files that were modified by the PR (safe for any other changes you made), deletes the review branch, and returns to your original branch.

## Troubleshooting

### "Cannot start review: you have uncommitted changes"

Commit or stash your changes before starting a review:

```bash
git stash
# or
git commit -am "WIP"
```

### "Not on a review branch"

You can only run `:PRReviewCleanup` when on a review branch (prefixed with `reviewing_` by default).

### Comments not showing

1. Make sure `show_comments = true` in your config
2. Check that you're authenticated with `gh auth status`
3. Try `:PRReviewComment` to manually show comments at cursor

### PR actions failing

Ensure GitHub CLI is properly authenticated:

```bash
gh auth status
gh auth login  # if not authenticated
```

## License

MIT

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
