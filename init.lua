local M = {}

-- Imports
local ask = require("llmnvim.ask")
local chat = require("llmnvim.chat")
local logs = require("llmnvim.logs")
local model_selector = require("llmnvim.model_selector")
local fragments = require("llmnvim.wip_fragments")

-- Default configuration
M.config = {
  no_stream = false,
  key = nil,
  system_prompt = nil,
  template = nil,
  continue_conversation = false,
  conversation_id = nil,
  params = {},
  options = {},
  window = {
    type = "sidebar", -- "sidebar", "float", or "bottom"
    sidebar = {
      side = "right", -- "left" or "right"
      width = 0.3, -- 30% of editor width
      min_width = 40, -- Minimum 40 columns
    },
    bottom = {
      height = 0.3, -- 30% of editor height
      min_height = 15, -- Minimum 15 lines
    },
    float = {
      border = "rounded",
      width = 80,
      height = 20,
      title = "LLM Chat",
    },
  },
}

-- Utility function to create a window based on config
function M.create_window(buf, title)
  local cfg = M.config.window
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  if cfg.type == "sidebar" then
    local width = math.max(math.floor(vim.o.columns * cfg.sidebar.width), cfg.sidebar.min_width)
    local cmd = cfg.sidebar.side == "left" and "topleft vsplit" or "botright vsplit"
    vim.cmd(cmd)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_width(win, width)
    vim.api.nvim_win_set_option(win, "wrap", false)
    vim.api.nvim_win_set_option(win, "cursorline", true)
    return win
  elseif cfg.type == "bottom" then
    local height = math.max(math.floor(vim.o.lines * cfg.bottom.height), cfg.bottom.min_height)
    vim.cmd("botright split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_height(win, height)
    vim.api.nvim_win_set_option(win, "wrap", false)
    vim.api.nvim_win_set_option(win, "cursorline", true)
    return win
  else
    -- Float window for backward compatibility
    local width = math.max(math.floor(vim.o.columns * 0.8), cfg.float.width)
    local height = math.floor(vim.o.lines * 0.7)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 3)
    return vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      border = cfg.float.border,
      title = title or cfg.float.title,
      title_pos = "center",
    })
  end
end

-- Setup function
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

-- Functions
function M.start_model_selector()
  model_selector.start_model_selector(M.config)
end

function M.start_chat()
  chat.start_chat(M.config)
end

function M.start_fragments()
  fragments.start_fragments_manager(M.config)
end

function M.start_ask()
  ask.start_ask(M.config)
end

function M.start_logs()
  logs.start_logs(M.config)
end

-- Commands
vim.api.nvim_create_user_command("LLMAsk", M.start_ask, { desc = "Open LLM ask window" })
vim.api.nvim_create_user_command("LLMChat", M.start_chat, { desc = "Open LLM chat window" })
vim.api.nvim_create_user_command("LLMLogs", M.start_logs, { desc = "Open LLM log window" })
vim.api.nvim_create_user_command("LLMSelectModel", M.start_model_selector, { desc = "Open LLM model selector window" })
-- vim.api.nvim_create_user_command("LLMFragments", M.start_fragments, { desc = "Open LLM fragment window" })

-- Keybindings
vim.keymap.set("n", "<leader>aa", "<cmd>LLMAsk<cr>", { desc = "Open LLM Ask" })
vim.keymap.set("n", "<leader>ac", "<cmd>LLMChat<cr>", { desc = "Open LLM Chat" })
vim.keymap.set("n", "<leader>al", "<cmd>LLMLogs<cr>", { desc = "Open LLM Log" })
vim.keymap.set("n", "<leader>am", "<cmd>LLMSelectModel<cr>", { desc = "Select LLM Model" })
--vim.keymap.set("n", "<leader>lf", "<cmd>LLMFragments<cr>", { desc = "Open LLM Fragments" })

return M
