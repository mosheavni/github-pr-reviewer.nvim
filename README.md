# PR Reviewer for Neovim

A powerful Neovim plugin for reviewing GitHub Pull Requests directly in your editor. Review PRs with the full power of your development environment - LSP, navigation, favorite files, and all your familiar tools.

## Why This Plugin?

**Traditional PR review tools force you into a limited web interface.** This plugin brings PR reviews into your Neovim environment where you have:

- 🚀 **Full LSP support** - Jump to definitions, find references, see type information while reviewing
- 📁 **Your favorite navigation tools** - Use arrow.nvim, harpoon, telescope, or any file navigation plugin
- 🔍 **See the full codebase** - Not limited to just the changed lines - explore the entire context
- ⚡ **Efficient workflows** - Built-in keybindings for navigation, quickfix integration, and smart change tracking
- 💬 **Comprehensive comment management** - Add, edit, delete, reply to comments with a great UX
- 📝 **Pending comments** - Draft comments locally and submit them all together when you're ready
- 🎯 **Context-aware** - View conversation threads, see file previews, and navigate with ease

**Review faster, review better.** Use the same environment where you write code to review it.

## Features

### Core Review Features
- ✅ **Review PRs locally** - Checkout PR changes as unstaged modifications
- ✅ **Session persistence** - Resume reviews after restarting Neovim
- ✅ **Fork PR support** - Automatically handles PRs from forks
- ✅ **Review requests** - List PRs where you're requested as reviewer with viewed status
- ✅ **Review buffer** - Interactive file browser showing all changed files with status
- ✅ **Change tracking** - See your progress through changes with a floating indicator
- ✅ **Inline diff** - Built-in diff visualization (no gitsigns required)
- ✅ **Quickfix integration** - Navigate modified files with `:cnext`/`:cprev`

### Comment Management
- 💬 **View comments inline** - PR comments appear as virtual text
- 💬 **Add line comments** - Comment on specific lines with context
- 💬 **Pending comments** - Draft comments locally, submit all at once
- 💬 **List all comments** - Browse all PR comments (posted + pending) with file preview
- 💬 **Reply to comments** - Continue conversation threads
- 💬 **Edit/Delete** - Modify or remove your comments
- 💬 **Comment threads** - View full conversation context when replying

### Review Actions
- ✓ **Approve PRs** - Submit approval with optional comment
- ✗ **Request changes** - Request changes with explanation
- 📊 **PR Info** - View stats, reviews, merge status, CI checks
- 🌐 **Open in browser** - Quick access to PR on GitHub
- 🎨 **Interactive menu** - `:PR` command for quick access to all features

### UI & Pickers
- 🔍 **Multiple picker support** - Native `vim.ui.select`, Telescope, or fzf-lua
- 🔍 **File previews** - See file content and context when selecting comments
- 🎨 **Smart formatting** - Shows file paths, authors, status, and comment previews
- ⌨️ **Keyboard-driven** - Efficient navigation with configurable keybindings

## Requirements

- Neovim >= 0.11.0
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- Git
- Optional: [bat](https://github.com/sharkdp/bat) for syntax-highlighted previews in fzf-lua

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "otavioschwanck/pr-reviewer.nvim",
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
  "otavioschwanck/pr-reviewer.nvim",
  config = function()
    require("pr-reviewer").setup()
  end
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'otavioschwanck/pr-reviewer.nvim'

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

### Main Menu

| Command | Description |
|---------|-------------|
| `:PR` or `:PRReviewMenu` | Show interactive menu with all available actions |

### Review Workflow

| Command | Description |
|---------|-------------|
| `:PRReview` | Select and start reviewing a PR |
| `:PRListReviewRequests` | List PRs where you are requested as reviewer |
| `:PRReviewCleanup` | End review, clean up changes, return to previous branch |
| `:PRInfo` | Show PR information (stats, reviews, merge status) |
| `:PROpen` | Open PR in browser |
| `:PRLoadLastSession` | Restore last PR review session (after restarting Neovim) |
| `:PRReviewBuffer` | Toggle review buffer (interactive file browser) |

### Comments

| Command | Description |
|---------|-------------|
| `:PRReviewComment` | Show comments at cursor line (also shows on `CursorHold`) |
| `:PRLineComment` | Add a review comment on the current line |
| `:PRPendingComment` | Add a pending comment (submitted with approval/rejection) |
| `:PRListPendingComments` | List all pending comments and navigate to selected one |
| `:PRListAllComments` | List ALL comments (pending + posted) with file preview |
| `:PRReply` | Reply to a comment on the current line |
| `:PREditComment` | Edit your comment (works for both pending and posted) |
| `:PRDeleteComment` | Delete your comment on the current line |
| `:PRComment` | Add a general comment to the PR |

### Review Actions

| Command | Description |
|---------|-------------|
| `:PRApprove` | Approve the PR (submits pending comments if any) |
| `:PRRequestChanges` | Request changes on the PR (submits pending comments if any) |

## Quick Start

### The Efficient Way to Review PRs

1. **Start the review**
   ```vim
   :PR
   " or
   :PRListReviewRequests
   ```

2. **Use the Review Buffer** (`:PRReviewBuffer` or `b` in the menu)
   - See all changed files at a glance
   - Check which files you've already reviewed (✓ marked)
   - Jump to any file instantly
   - Mark files as viewed with `<CR>`

3. **Navigate like you're coding**
   - Use `gd` to jump to definitions (LSP)
   - Use `gr` to find references (LSP)
   - Use `K` to see documentation (LSP)
   - Use Telescope/fzf to search across the codebase
   - Use arrow/harpoon to mark important files for quick access
   - **You're not limited to changed lines** - explore the full context!

4. **Add comments efficiently**
   - Use `:PRPendingComment` to draft comments as you review
   - All pending comments are saved locally
   - Submit them all at once with `:PRApprove` or `:PRRequestChanges`
   - Preview all pending comments before submitting

5. **Track your progress**
   - Floating indicator shows: viewed status, change position, stats, comments
   - Press `<CR>` on a file to mark as viewed and jump to next file
   - Review buffer shows overall progress

## Usage Guide

### Starting a Review

1. Make sure you have no uncommitted changes (the plugin will warn you)
2. Run `:PRListReviewRequests` to see PRs requesting your review, or `:PRReview` for all open PRs
3. Select a PR from the list
4. The plugin will:
   - Save your current branch
   - Create a review branch
   - Soft-merge the PR changes (unstaged)
   - Fetch all PR comments
   - Open the review buffer or quickfix list with all modified files

### Review Requests

Use `:PRListReviewRequests` to see PRs where you've been requested as a reviewer:

- Shows PR info with additions/deletions stats and viewed status
- **✓ viewed** indicator shows if you've already reviewed all files
- **Enter**: Start reviewing the selected PR
- **Ctrl-v** (fzf-lua/telescope): Mark PR as viewed without starting review

The fzf-lua/telescope pickers show a hint header with available actions.

### Review Buffer (Interactive File Browser)

Press `:PRReviewBuffer` or use `b` in the `:PR` menu to open an interactive file browser:

```
┌─ PR #123: Add authentication ─────────────────────┐
│                                                    │
│  ✓ app/auth/login.rb                   +45 -12    │
│  ○ app/auth/session.rb                 +23 -5     │
│  ○ spec/auth/login_spec.rb             +67 -0     │
│  ✓ config/routes.rb                    +2 -0      │
│                                                    │
│  Progress: 2/4 files viewed                       │
│  <CR>: Open file | v: Toggle viewed | q: Close    │
└────────────────────────────────────────────────────┘
```

Features:
- **✓** = File has been marked as viewed
- **○** = File not yet viewed
- Shows additions/deletions for each file
- Press `<CR>` to open a file
- Press `v` to toggle viewed status
- Press `q` to close
- Automatically refreshes as you mark files viewed

### Navigating Changes

The plugin includes built-in navigation that only works during PR review mode:

**Hunk Navigation** (within a file):
- `<C-j>` (default) - Jump to next hunk
- `<C-k>` (default) - Jump to previous hunk

**File Navigation** (between modified files):
- `<C-l>` (default) - Go to next file in quickfix
- `<C-h>` (default) - Go to previous file in quickfix
- `<CR>` (default) - Mark file as viewed and jump to next file

All keybindings are configurable in setup and only activate during PR review mode.

You can also use the quickfix list commands:
- `:cnext` or `]q` - Go to next modified file
- `:cprev` or `[q` - Go to previous modified file

### Change Progress Indicator

When reviewing a file with changes, you'll see a floating indicator in the top-right corner showing:

```
┌──────────────────────────┐
│ ✓ Viewed                 │
│ 2/5 changes              │
│ +15 ~3 -8                │
│ 💬 2 comments            │
│ 📝 1 pending             │
│ <CR>: Mark as viewed     │
└──────────────────────────┘
```

- **Viewed status**: Shows if the current file has been marked as viewed
- **Change progress**: Current change position (groups consecutive changed lines together)
- **Stats**: +additions ~modifications -deletions
- **Comments**: Number of posted PR comments in this file
- **Pending**: Number of pending comments you've drafted
- **Mark as viewed**: Press `<CR>` to mark file as viewed and jump to next file

### Pending Comments Workflow

One of the most efficient ways to review is using **pending comments**:

1. As you review, add pending comments with `:PRPendingComment`
2. These are saved locally (not submitted to GitHub yet)
3. Continue reviewing, adding more pending comments
4. Use `:PRListPendingComments` to review all your draft comments
5. When ready, run `:PRApprove` or `:PRRequestChanges`
6. The plugin shows a preview of ALL pending comments before submission
7. Confirm to submit your review + all pending comments at once

Benefits:
- Draft your thoughts as you review without interrupting your flow
- Review all your comments before submitting
- Submit everything together as a cohesive review
- Edit or delete pending comments before submission

### Viewing and Managing Comments

**Add Comments:**
- `:PRLineComment` - Add a review comment on the current line (submitted immediately)
- `:PRPendingComment` - Add a pending comment (submitted with approval/rejection)
- `:PRComment` - Add a general PR comment

**View Comments:**
- Comments appear as virtual text on lines automatically
- `:PRReviewComment` - Show comments at cursor line in a popup
- `:PRListAllComments` - Browse ALL comments with file preview

**Manage Comments:**
- `:PRReply` - Reply to a comment (cannot reply to pending comments)
- `:PREditComment` - Edit your comment (works for both pending and posted)
- `:PRDeleteComment` - Delete your comment

**List All Comments** (`:PRListAllComments`):
- Shows both pending and posted comments
- Includes author, file path, line number
- **Telescope**: Full file preview with syntax highlighting and comment highlighted
- **fzf-lua**: File preview with bat/cat showing context around the comment
- Navigate to comment location on selection

### Session Persistence

The plugin automatically saves your review session state:

- **Auto-save**: Session is saved when you start a review
- **Per-project**: Each project directory gets its own session file
- **What's saved**: PR number, previous branch, modified files, viewed status, pending comments
- **Auto-cleanup**: Session file is deleted when you run `:PRReviewCleanup`

To restore a session after restarting Neovim:

```vim
:PRLoadLastSession
```

Session files are stored in `~/.local/share/nvim/pr-reviewer-sessions/`.

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

### Finishing the Review

1. Run `:PRApprove` to approve, or `:PRRequestChanges` to request changes
   - If you have pending comments, they'll be shown for confirmation
   - All pending comments are submitted with your review
2. Run `:PRReviewCleanup` to:
   - Revert all PR changes
   - Delete the review branch
   - Return to your original branch
   - Close the quickfix window
   - Clear the session

## Complete Workflow Example

Here's a complete workflow for reviewing a PR efficiently:

```vim
" 1. See review requests
:PRListReviewRequests
" Select PR #42 from the list

" 2. Open the review buffer to see all files
:PRReviewBuffer

" 3. Jump to a file by pressing <CR>

" 4. Navigate with full LSP support
gd              " Go to definition
gr              " Find references
K               " See documentation

" 5. Use your favorite navigation tools
" - Telescope to search across files
" - Arrow/harpoon to mark important files
" - Normal Neovim navigation

" 6. Add pending comments as you review
:PRPendingComment
" Type your comment, press <C-s> to save locally

" 7. Mark file as viewed and go to next
<CR>            " Configured key to mark as viewed

" 8. Continue reviewing other files
<C-l>           " Next file
<C-h>           " Previous file

" 9. List all your pending comments to review them
:PRListAllComments

" 10. Approve and submit all pending comments at once
:PRApprove
" Review the preview, confirm to submit

" 11. Clean up and return to your work
:PRReviewCleanup
```

## Recommended Keymaps

```lua
-- Quick menu access
vim.keymap.set("n", "<leader>p", ":PR<CR>", { desc = "PR Review Menu" })

-- Review workflow
vim.keymap.set("n", "<leader>pr", ":PRReview<CR>", { desc = "Start PR review" })
vim.keymap.set("n", "<leader>pl", ":PRListReviewRequests<CR>", { desc = "List review requests" })
vim.keymap.set("n", "<leader>pc", ":PRReviewCleanup<CR>", { desc = "Cleanup PR review" })
vim.keymap.set("n", "<leader>pi", ":PRInfo<CR>", { desc = "Show PR info" })
vim.keymap.set("n", "<leader>po", ":PROpen<CR>", { desc = "Open PR in browser" })
vim.keymap.set("n", "<leader>pb", ":PRReviewBuffer<CR>", { desc = "Toggle review buffer" })

-- Comments
vim.keymap.set("n", "<leader>pC", ":PRLineComment<CR>", { desc = "Add line comment" })
vim.keymap.set("n", "<leader>pP", ":PRPendingComment<CR>", { desc = "Add pending comment" })
vim.keymap.set("n", "<leader>pv", ":PRListAllComments<CR>", { desc = "List all comments" })
vim.keymap.set("n", "<leader>pp", ":PRListPendingComments<CR>", { desc = "List pending comments" })
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

### arrow.nvim / harpoon

Mark files you want to return to during review:

```lua
-- With arrow.nvim
require("arrow").setup()

-- With harpoon
require("harpoon").setup()
```

Both plugins work seamlessly during PR review, letting you mark important files and jump between them quickly.

### LSP (Native Neovim LSP or nvim-lspconfig)

Your LSP is fully functional during PR review:
- `gd` - Go to definition
- `gr` - Find references
- `K` - Hover documentation
- `<leader>rn` - Rename
- All your LSP keybindings work normally

**This is a huge advantage over web-based PR review** - you can explore the full codebase with full language intelligence.

### Telescope / fzf-lua

Set your preferred picker in the config:

```lua
require("pr-reviewer").setup({
  picker = "telescope",  -- or "fzf-lua" or "native"
})
```

Telescope and fzf-lua provide enhanced comment browsing with file previews.

### gitsigns.nvim (Optional)

**gitsigns.nvim is optional** - the plugin has built-in inline diff visualization. However, gitsigns can still be useful for:

- Hunk navigation with `]h` and `[h`
- Interactive hunk staging/unstaging
- Additional git blame and diff features

If you prefer to use gitsigns instead of the built-in inline diff:

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

## How It Works

1. **Starting review**: Creates a branch from the PR's base branch, then soft-merges the PR's head branch without committing. This leaves all PR changes as unstaged modifications.

2. **Fork support**: Automatically detects fork PRs using GitHub's `isCrossRepository` field, adds the fork as a remote, and fetches from it.

3. **Comments**: Fetches PR comments via GitHub API and displays them as virtual text. Comments are cached per buffer for performance.

4. **Pending comments**: Stored locally in session files (JSON format) and submitted to GitHub when you approve/request changes.

5. **Change tracking**: Parses `git diff` output to identify changed lines and groups consecutive lines into "hunks" for the progress indicator.

6. **Cleanup**: Reverts only the files that were modified by the PR (safe for any other changes you made), deletes the review branch, and returns to your original branch.

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

### "git fetch failed"

If you see this error, you might have old fork remotes that are no longer accessible. Clean them up:

```bash
git remote | grep "^fork-" | xargs -I {} git remote remove {}
```

The plugin now has a fallback that tries `git fetch origin` if `git fetch --all` fails.

### Preview not working in fzf-lua

Install [bat](https://github.com/sharkdp/bat) for syntax-highlighted previews:

```bash
# macOS
brew install bat

# Ubuntu/Debian
apt install bat

# Arch
pacman -S bat
```

If `bat` is not available, the plugin falls back to `cat`.

## Performance

The plugin is designed for performance:

- **Lazy loading**: Comments are only fetched when entering a buffer
- **Caching**: Comments are cached per buffer to avoid repeated API calls
- **Efficient diff parsing**: Only parses diff output once per file
- **Background jobs**: File operations use async jobs when possible
- **Session files**: Small JSON files for fast load/save

Typical startup time: <100ms for a PR with 20+ files.

## License

MIT

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development

To work on this plugin:

1. Clone the repository
2. Make your changes
3. Test with `:luafile %` in your Neovim config
4. Submit a PR with a clear description of the changes

## Credits

Created by [Your Name]

Inspired by the need for a better PR review experience in Neovim.

Special thanks to the Neovim community and all contributors!
