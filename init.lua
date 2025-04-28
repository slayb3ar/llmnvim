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
  float_opts = {
    border = "rounded",
    width = 80,
    height = 20,
    title = "LLM Chat",
  },
}

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
