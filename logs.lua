local M = {}

-- State
local state = {
  buf = nil,
  win = nil,
  config = {},
}

-- Get responsive window dimensions
local function get_dimensions()
  local width = math.max(math.floor(vim.o.columns * 0.8), 80)
  local height = math.floor(vim.o.lines * 0.7)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  return width, height, row, col
end

-- Build llm logs command arguments
local function build_args(cfg)
  local args = { "logs" }

  -- Add count option (-n)
  if cfg.count then
    vim.list_extend(args, { "-n", tostring(cfg.count) })
  end

  -- Add model filter (-m)
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
  vim.api.nvim_buf_set_option(output_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(output_buf, "filetype", "markdown")

  -- Set up window dimensions
  local width, height, row, col = get_dimensions()
  state.buf = output_buf
  state.win = vim.api.nvim_open_win(output_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    title = "LLM Logs",
    title_pos = "center",
  })

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
