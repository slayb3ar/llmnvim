local M = {}

local state = {
  chat_buf = nil,
  chat_win = nil,
  config = {},
  handle = nil,
  stdin = nil,
  stdout = nil,
  line_buffer = "",
}

local function build_args(cfg)
  local args = { "chat" }

  if cfg.system_prompt then
    vim.list_extend(args, { "-s", cfg.system_prompt })
  end
  if cfg.conversation_id then
    vim.list_extend(args, { "--cid", cfg.conversation_id })
  elseif cfg.continue_conversation then
    table.insert(args, "-c")
  end
  if cfg.template then
    vim.list_extend(args, { "-t", cfg.template })
  end
  for _, param in ipairs(cfg.params or {}) do
    vim.list_extend(args, { "-p", unpack(param) })
  end
  for _, opt in ipairs(cfg.options or {}) do
    vim.list_extend(args, { "-o", unpack(opt) })
  end
  if cfg.no_stream then
    table.insert(args, "--no-stream")
  end
  if cfg.key then
    vim.list_extend(args, { "--key", cfg.key })
  end

  -- TODO: REMOVE
  vim.list_extend(args, { "-o", "unlimited", "1" })
  return args
end

local function append_chat(lines)
  if not state.chat_buf then
    return
  end
  vim.schedule(function()
    vim.api.nvim_buf_set_option(state.chat_buf, "modifiable", true)

    -- Convert single string to table if needed
    local input_lines = type(lines) == "table" and lines or { lines }
    local processed_lines = {}

    -- Process lines to add empty lines between paragraphs
    for i, line in ipairs(input_lines) do
      table.insert(processed_lines, line)
      -- Add an empty line after non-empty lines to separate paragraphs
      -- Avoid adding empty lines after the last line or if the next line is already empty
      if line ~= "" and (i < #input_lines or input_lines[i] ~= "") then
        table.insert(processed_lines, "")
      end
    end

    -- Append processed lines to the buffer
    vim.api.nvim_buf_set_lines(state.chat_buf, -1, -1, false, processed_lines)
    vim.api.nvim_buf_set_option(state.chat_buf, "modifiable", false)
    -- Autoscroll to the latest content
    -- vim.api.nvim_win_set_cursor(state.chat_win, { vim.api.nvim_buf_line_count(state.chat_buf), 0 })
  end)
end

local function start_llm_process(cfg)
  if state.handle then
    return
  end -- already running

  local args = build_args(cfg)
  local stdout = vim.loop.new_pipe(false)
  local stdin = vim.loop.new_pipe(false)

  state.line_buffer = ""

  state.handle = vim.loop.spawn("llm", {
    args = args,
    stdio = { stdin, stdout, nil },
  }, function()
    -- Append any remaining buffered content
    if state.line_buffer ~= "" then
      append_chat(state.line_buffer)
      state.line_buffer = ""
    end
    append_chat("\n[Process exited]")
    state.handle = nil
    state.stdin:close()
    state.stdout:close()
  end)

  state.stdin = stdin
  state.stdout = stdout

  stdout:read_start(function(err, chunk)
    if err then
      append_chat("Error: " .. err)
    elseif chunk then
      state.line_buffer = state.line_buffer .. chunk
      local lines = {}
      local last_newline = 0
      for i = 1, #state.line_buffer do
        if state.line_buffer:sub(i, i) == "\n" then
          local line = state.line_buffer:sub(last_newline + 1, i - 1)
          if line ~= "" then
            table.insert(lines, line)
          end
          last_newline = i
        end
      end
      state.line_buffer = state.line_buffer:sub(last_newline + 1)
      if #lines > 0 then
        append_chat(lines)
      end
    end
  end)
end

local function send_to_llm(input)
  if not state.stdin then
    append_chat("[No active chat process]")
    return
  end
  state.stdin:write(input .. "\n")
end

-- New function to fetch and format previous conversation logs
local function fetch_previous_conversation()
  local logs = {}
  local handle = io.popen("llm logs -c --json")
  if not handle then
    return logs
  end

  local result = handle:read("*a")
  handle:close()

  -- Parse JSON output
  local success, parsed = pcall(vim.fn.json_decode, result)
  if not success or not parsed then
    return logs
  end

  -- Format each log entry
  for _, entry in ipairs(parsed) do
    -- Add prompt with "You: " prefix
    if entry.prompt and entry.prompt ~= "" then
      table.insert(logs, "You: " .. entry.prompt)
      table.insert(logs, "")
    end
    -- Add response
    if entry.response and entry.response ~= "" then
      -- Split response into lines for proper formatting
      for line in entry.response:gmatch("[^\n]+") do
        table.insert(logs, line)
      end
      table.insert(logs, "")
    end
  end

  return logs
end

local function open_chat_ui()
  state.chat_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(state.chat_buf, "filetype", "markdown")

  -- Use centralized window creation
  state.chat_win = require("llmnvim").create_window(state.chat_buf, "LLM Chat")

  vim.api.nvim_buf_set_option(state.chat_buf, "wrap", true)
  vim.api.nvim_win_set_option(state.chat_win, "wrap", true)
  vim.api.nvim_win_set_option(state.chat_win, "linebreak", true)
  vim.api.nvim_win_set_option(state.chat_win, "breakindent", true)

  -- Initialize chat window content
  local initial_lines = {
    "LLM Chat Interface",
    "──────────────────",
    "",
    "Type your message and press <Enter>",
    "Press <Esc> or q to close the window.",
    "",
  }

  -- If continue_conversation is true, fetch and append previous conversation
  if state.config.continue_conversation then
    local previous_logs = fetch_previous_conversation()
    if #previous_logs > 0 then
      vim.list_extend(initial_lines, previous_logs)
      table.insert(initial_lines, "") -- Add a separator
    end
  end

  append_chat(initial_lines)

  -- Define close_chat function
  local function close_chat()
    if state.handle then
      state.stdin:write("exit\n")
      state.stdin:close()
      state.stdout:close()
      state.handle:kill("sigint")
      state.handle:close()
      state.handle = nil
    end
    if state.chat_win and vim.api.nvim_win_is_valid(state.chat_win) then
      vim.api.nvim_win_close(state.chat_win, true)
    end
  end

  -- Keybindings
  vim.keymap.set("n", "<CR>", function()
    vim.ui.input({ prompt = "You: " }, function(input)
      if input and input ~= "" then
        append_chat({ "", "You: " .. input, "" })
        send_to_llm(input)
      end
    end)
  end, { buffer = state.chat_buf })

  vim.keymap.set("n", "<Esc>", close_chat, { buffer = state.chat_buf })
  vim.keymap.set("n", "q", close_chat, { buffer = state.chat_buf })

  -- Start the persistent chat subprocess
  start_llm_process(state.config)
end

local function open_options_ui(default_config)
  -- Sanitize system_prompt to avoid newlines
  local system_prompt_display = (default_config.system_prompt or "[None]"):gsub("\n.*", "...") -- Truncate after first line
  local lines = {
    "LLM Chat Options",
    "────────────────",
    "",
    "[c] Continue last conversation: " .. tostring(default_config.continue_conversation),
    "[s] System prompt: " .. system_prompt_display,
    "[Enter] Start Chat",
    "[q / Esc] Cancel",
  }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "filetype", "llm-chat-options")

  -- Use centralized window creation
  local win = require("llmnvim").create_window(buf, "LLM Chat Config")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local function refresh()
    system_prompt_display = (default_config.system_prompt or "[None]"):gsub("\n.*", "...")
    lines[4] = "[c] Continue last conversation: " .. tostring(default_config.continue_conversation)
    lines[5] = "[s] System prompt: " .. system_prompt_display
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end

  vim.keymap.set("n", "c", function()
    default_config.continue_conversation = not default_config.continue_conversation
    refresh()
  end, { buffer = buf })

  vim.keymap.set("n", "s", function()
    vim.ui.input({ prompt = "System prompt:" }, function(input)
      if input then
        default_config.system_prompt = input
        refresh()
      end
    end)
  end, { buffer = buf })

  vim.keymap.set("n", "<CR>", function()
    state.config = vim.deepcopy(default_config)
    vim.api.nvim_win_close(win, true)
    open_chat_ui()
  end, { buffer = buf })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
end

function M.start_chat(config)
  open_options_ui(config)
end

return M
