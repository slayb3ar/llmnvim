local M = {}

-- State
local state = {
  buf = nil,
  win = nil,
  config = {},
}

-- Build llm logs command arguments
local function build_args(cfg)
  local args = { "logs" }

  -- Add count option (-n)
  if cfg.count then
    vim.list_extend(args, { "-n", tostring(cfg.count) })
  end

  -- Add model filter (-n)
  if cfg.model then
    vim.list_extend(args, { "-m", vim.fn.shellescape(cfg.model) })
  end

  -- Add query search (-q)
  if cfg.query then
    vim.list_extend(args, { "-q", vim.fn.shellescape(cfg.query) })
  end

  -- Add JSON output option
  if cfg.json then
    table.insert(args, "--json")
  end

  -- Add truncate option
  if cfg.truncate then
    table.insert(args, "-t")
  end

  -- Add short mode
  if cfg.short then
    table.insert(args, "-s")
  end

  -- Add usage information
  if cfg.usage then
    table.insert(args, "-u")
  end

  return args
end

-- Execute llm logs and display output
local function display_logs()
  local args = build_args(state.config)

  -- Create buffer for logs
  local output_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(output_buf, "filetype", "markdown")

  -- Use centralized window creation
  state.buf = output_buf
  state.win = require("llmnvim").create_window(output_buf, "LLM Logs")

  -- Enable wrapping and scrolling
  vim.api.nvim_buf_set_option(output_buf, "wrap", true)
  vim.api.nvim_win_set_option(state.win, "wrap", true)
  vim.api.nvim_win_set_option(state.win, "linebreak", true)
  vim.api.nvim_win_set_option(state.win, "breakindent", true)
  vim.api.nvim_win_set_option(state.win, "scrolloff", 5)

  -- Initialize with "Loading..." message
  vim.api.nvim_buf_set_option(output_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { "Loading logs..." })

  -- Execute llm logs command
  local output = vim.fn.systemlist("llm " .. table.concat(args, " "))
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { "Error executing llm logs: " .. table.concat(output, "\n") })
    vim.api.nvim_buf_set_option(output_buf, "modifiable", false)
    return
  end

  -- Display logs
  vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, output)
  vim.api.nvim_buf_set_option(output_buf, "modifiable", false)

  -- Keybindings
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = output_buf, noremap = true, silent = true })

  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, { buffer = output_buf, noremap = true, silent = true })

  -- Optional: Add keybinding to refresh logs
  vim.keymap.set("n", "r", function()
    M.close()
    display_logs()
  end, { buffer = output_buf, noremap = true, silent = true })
end

-- Close the logs window
function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
end

-- Start the logs viewer
function M.start_logs(config)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  state.config = vim.tbl_deep_extend("force", {
    count = 3, -- Default to showing 3 most recent logs
    json = false,
    truncate = false,
    short = false,
    usage = false,
  }, config or {})

  display_logs()
end

return M
