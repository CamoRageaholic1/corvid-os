-- ===========================================================================
-- Corvid OS — default Neovim config (/etc/skel, copied to every new user)
-- ---------------------------------------------------------------------------
-- Design goals:
--   * SELF-CONTAINED. Zero plugins are required — this file works on the very
--     first launch with NO network access. That matters for a live/offline
--     image: nvim must open instantly, not try to clone plugins over a network
--     that may not exist yet.
--   * Sensible, advanced-user defaults + native LSP scaffolding that is ready
--     the moment you install a language server (no framework in the way).
--   * A lazy.nvim bootstrap is provided but COMMENTED OUT at the bottom. If you
--     opt in, note that it DOWNLOADS lazy.nvim + your plugins from GitHub on
--     first launch — so only enable it once you have a network.
-- ===========================================================================

local g = vim.g
local opt = vim.opt

-- Leader keys (set before any mapping so <leader> resolves correctly).
g.mapleader = " "
g.maplocalleader = " "

-- --- General ---------------------------------------------------------------
opt.mouse = "a"                 -- mouse in all modes (resize splits, etc.)
opt.clipboard = "unnamedplus"   -- use the system clipboard by default
opt.undofile = true             -- persistent undo across sessions
opt.swapfile = false            -- no .swp litter; undofile covers recovery
opt.updatetime = 250            -- snappier CursorHold / diagnostics
opt.timeoutlen = 400            -- quicker which-key-style mapping timeout
opt.confirm = true              -- ask to save instead of failing :q on changes
opt.hidden = true               -- switch buffers without saving

-- --- UI --------------------------------------------------------------------
opt.number = true
opt.relativenumber = true       -- relative + absolute (hybrid) line numbers
opt.cursorline = true
opt.signcolumn = "yes"          -- always show sign column (no text jitter)
opt.scrolloff = 8               -- keep context above/below the cursor
opt.sidescrolloff = 8
opt.wrap = false
opt.termguicolors = true        -- 24-bit color (Konsole supports it)
opt.showmode = false            -- mode already shown in the statusline
opt.splitright = true
opt.splitbelow = true
opt.list = true                 -- reveal hidden whitespace
opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }

-- A clean, dependency-free default colorscheme that ships with Neovim.
pcall(vim.cmd.colorscheme, "habamax")

-- --- Search ----------------------------------------------------------------
opt.ignorecase = true
opt.smartcase = true            -- case-sensitive only if the query has a capital
opt.incsearch = true
opt.hlsearch = true

-- --- Indentation (4-space soft tabs; language files can override) ----------
opt.expandtab = true
opt.shiftwidth = 4
opt.tabstop = 4
opt.softtabstop = 4
opt.smartindent = true
opt.breakindent = true

-- --- Completion ------------------------------------------------------------
opt.completeopt = { "menuone", "noselect" }
opt.pumheight = 12

-- ===========================================================================
-- Keymaps
-- ===========================================================================
local map = vim.keymap.set

-- Clear search highlight with <Esc>.
map("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "Clear search highlight" })

-- Quality-of-life: save / quit.
map("n", "<leader>w", "<cmd>write<CR>", { desc = "Save file" })
map("n", "<leader>q", "<cmd>quit<CR>",  { desc = "Quit window" })

-- Move between splits with Ctrl + hjkl.
map("n", "<C-h>", "<C-w>h", { desc = "Go to left split" })
map("n", "<C-j>", "<C-w>j", { desc = "Go to lower split" })
map("n", "<C-k>", "<C-w>k", { desc = "Go to upper split" })
map("n", "<C-l>", "<C-w>l", { desc = "Go to right split" })

-- Keep the cursor centered when jumping/half-paging and searching.
map("n", "<C-d>", "<C-d>zz")
map("n", "<C-u>", "<C-u>zz")
map("n", "n", "nzzzv")
map("n", "N", "Nzzzv")

-- Move selected lines up/down in visual mode.
map("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move selection down" })
map("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move selection up" })

-- Toggle relative numbers (handy for pairing / screenshots).
map("n", "<leader>rn", function() opt.relativenumber = not opt.relativenumber:get() end,
    { desc = "Toggle relative numbers" })

-- ===========================================================================
-- Autocommands
-- ===========================================================================
local aug = vim.api.nvim_create_augroup("corvid", { clear = true })

-- Briefly highlight yanked text.
vim.api.nvim_create_autocmd("TextYankPost", {
    group = aug,
    callback = function() vim.highlight.on_yank({ timeout = 150 }) end,
})

-- Trim trailing whitespace on save (skip markdown, where it can be meaningful).
vim.api.nvim_create_autocmd("BufWritePre", {
    group = aug,
    callback = function()
        if vim.bo.filetype == "markdown" then return end
        local view = vim.fn.winsaveview()
        vim.cmd([[keeppatterns %s/\s\+$//e]])
        vim.fn.winrestview(view)
    end,
})

-- 2-space indent for common web / config filetypes.
vim.api.nvim_create_autocmd("FileType", {
    group = aug,
    pattern = { "lua", "json", "jsonc", "yaml", "html", "css", "scss",
                "javascript", "typescript", "javascriptreact", "typescriptreact" },
    callback = function()
        vim.bo.shiftwidth = 2
        vim.bo.tabstop = 2
        vim.bo.softtabstop = 2
    end,
})

-- ===========================================================================
-- Native LSP scaffolding (NO plugins, NO network)
-- ---------------------------------------------------------------------------
-- Neovim ships a built-in LSP client. The buffer-local keymaps below only
-- activate once a server attaches, so they cost nothing until you actually
-- install a language server (e.g. `sudo apt install clangd`, `pipx install
-- python-lsp-server`, `npm i -g typescript-language-server`, etc.).
--
-- To start a server, add a vim.lsp.start(...) call for it — example for clangd
-- is provided commented out. This keeps you on the raw, plugin-free LSP API.
-- ===========================================================================
vim.api.nvim_create_autocmd("LspAttach", {
    group = aug,
    callback = function(ev)
        local o = { buffer = ev.buf, silent = true }
        map("n", "gd", vim.lsp.buf.definition,      vim.tbl_extend("force", o, { desc = "LSP: go to definition" }))
        map("n", "gD", vim.lsp.buf.declaration,     vim.tbl_extend("force", o, { desc = "LSP: go to declaration" }))
        map("n", "gr", vim.lsp.buf.references,       vim.tbl_extend("force", o, { desc = "LSP: references" }))
        map("n", "gi", vim.lsp.buf.implementation,   vim.tbl_extend("force", o, { desc = "LSP: implementation" }))
        map("n", "K",  vim.lsp.buf.hover,            vim.tbl_extend("force", o, { desc = "LSP: hover" }))
        map("n", "<leader>rn", vim.lsp.buf.rename,   vim.tbl_extend("force", o, { desc = "LSP: rename" }))
        map("n", "<leader>ca", vim.lsp.buf.code_action, vim.tbl_extend("force", o, { desc = "LSP: code action" }))
        map("n", "<leader>f",  function() vim.lsp.buf.format({ async = true }) end,
            vim.tbl_extend("force", o, { desc = "LSP: format buffer" }))
    end,
})

-- Sane diagnostic display (works even with no server yet).
vim.diagnostic.config({
    virtual_text = true,
    severity_sort = true,
    float = { border = "rounded" },
})

-- Example: auto-start clangd for C/C++ if it is installed. Uncomment to use.
-- vim.api.nvim_create_autocmd("FileType", {
--     group = aug,
--     pattern = { "c", "cpp", "objc", "objcpp" },
--     callback = function(ev)
--         if vim.fn.executable("clangd") == 1 then
--             vim.lsp.start({ name = "clangd", cmd = { "clangd" },
--                 root_dir = vim.fs.root(ev.buf, { ".git", "compile_commands.json" }) })
--         end
--     end,
-- })

-- ===========================================================================
-- OPTIONAL: lazy.nvim plugin manager bootstrap  (DISABLED by default)
-- ---------------------------------------------------------------------------
-- Uncomment the block below to opt into a plugin ecosystem. On FIRST LAUNCH it
-- DOWNLOADS lazy.nvim from GitHub (and then your plugins), so only enable this
-- once the machine has network access. Left off so the stock image opens nvim
-- fully offline.
-- ---------------------------------------------------------------------------
-- local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
-- if not (vim.uv or vim.loop).fs_stat(lazypath) then
--     vim.fn.system({ "git", "clone", "--filter=blob:none",
--         "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath })
-- end
-- vim.opt.rtp:prepend(lazypath)
-- require("lazy").setup({
--     -- { "neovim/nvim-lspconfig" },
--     -- { "nvim-treesitter/nvim-treesitter", build = ":TSUpdate" },
--     -- { "nvim-telescope/telescope.nvim", dependencies = { "nvim-lua/plenary.nvim" } },
-- })
