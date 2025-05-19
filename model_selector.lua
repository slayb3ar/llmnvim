local M = {}

-- State
local state = {
  buf = nil,
  win = nil,
  models = {},
  default_model = nil,
}

-- Parse the output of llm models list
local function parse_models_output(output)
  local models = {}
  local providers = {}

  for _, line in ipairs(output) do
    if line ~= "" then
      -- Extract provider and model name
      local provider, model_info = line:match("^([^:]+): (.+)$")
      if provider and model_info then
        -- Extract model name and aliases if any
        local model_name, aliases = model_info:match("^([^%(]+)%s*%(aliases:%s*([^%)]+)%)?")
        if not model_name then
          model_name = model_info -- No aliases
        end

        model_name = model_name:gsub("%s+$", "") -- Trim trailing spaces

        local model = {
          provider = provider,
          name = model_name,
          aliases = aliases and aliases:gsub("%s+", "") or nil,
          display = line, -- Store full display text
        }

        table.insert(models, model)

        -- Track providers for grouping
        if not providers[provider] then
          providers[provider] = true
        end
      elseif line:match("^Default:") then
        -- Extract default model if present in the output
        local default = line:match("^Default:%s*(.+)$")
        if default then
          state.default_model = default:gsub("%s+$", "") -- Trim trailing spaces
        end
      end
    end
  end

  return models, vim.tbl_keys(providers)
end

-- Get current default model
local function get_default_model()
  local output = vim.fn.system("llm models default")
  return vim.trim(output)
end

-- Set model as default
local function set_default_model(model)
  vim.fn.system("llm models default " .. vim.fn.shellescape(model))
  vim.notify("Default model set to: " .. model, vim.log.levels.INFO)
end

-- Create the model selector window
function M.start_model_selector(config)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  -- Get models list
  local cmd_output = vim.fn.systemlist("llm models")
  state.models, providers = parse_models_output(cmd_output)

  -- Get current default model if not found in output
  if not state.default_model then
    state.default_model = get_default_model()
  end

  -- Prepare content for display
  local content = {
    "LLM MODEL SELECTOR",
    "─────────────────",
    "",
    "Default model: " .. state.default_model,
    "",
    "Available models (press Enter to set as default):",
    "─────────────────────────────────────────────────",
    "",
  }

  -- Add models to content
  for _, model in ipairs(state.models) do
    local prefix = model.name == state.default_model and "* " or "  "
    table.insert(content, prefix .. model.display)
  end

  table.insert(content, "")
  table.insert(content, "Press 'q' or <Esc> to close this window")

  -- Create buffer and window
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(state.buf, "filetype", "llm-model-selector")

  -- Use centralized window creation
  state.win = require("llmnvim").create_window(state.buf, "LLM Model Selector")

  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, content)
  vim.api.nvim_buf_set_option(state.buf, "modifiable", false)
  vim.api.nvim_win_set_option(state.win, "cursorline", true)

  -- Highlight the default model
  local ns_id = vim.api.nvim_create_namespace("llm_model_selector")
  for i, line in ipairs(content) do
    if line:match("^%*%s") then
      vim.api.nvim_buf_add_highlight(state.buf, ns_id, "DiffAdd", i - 1, 0, -1)
    end
  end

  -- Set cursor to current default model
  for i, line in ipairs(content) do
    if line:match("^%*%s") then
      vim.api.nvim_win_set_cursor(state.win, { i, 0 })
      break
    end
  end

  -- Set up key mappings
  vim.api.nvim_buf_set_keymap(state.buf, "n", "<CR>", "", {
    callback = function()
      local cursor = vim.api.nvim_win_get_cursor(state.win)
      local line_num = cursor[1]
      local line = vim.api.nvim_buf_get_lines(state.buf, line_num - 1, line_num, false)[1]

      -- Extract model name from line
      local provider, model_info = line:match("^%s*%*?%s*([^:]+): (.+)$")
      if provider and model_info then
        local model_name = model_info:match("^([^%(]+)")
        if model_name then
          model_name = vim.trim(model_name)
          set_default_model(model_name)
          state.default_model = model_name
          M.close()
          M.start_model_selector(config) -- Refresh the view
        end
      end
    end,
    noremap = true,
    silent = true,
  })

  vim.api.nvim_buf_set_keymap(state.buf, "n", "q", "", {
    callback = M.close,
    noremap = true,
    silent = true,
  })

  vim.api.nvim_buf_set_keymap(state.buf, "n", "<Esc>", "", {
    callback = M.close,
    noremap = true,
    silent = true,
  })

  -- Add search functionality
  vim.api.nvim_buf_set_keymap(state.buf, "n", "/", "", {
    callback = function()
      vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
      vim.api.nvim_command("/")
    end,
    noremap = true,
    silent = true,
  })
end

-- Close the model selector window
function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
end

return M
