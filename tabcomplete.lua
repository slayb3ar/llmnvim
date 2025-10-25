local M = {}

local state = {
  enabled = true,
  debug = true,
  completion_cache = {},
  active_completions = {},
  ghost_ns = vim.api.nvim_create_namespace("llm_tabcomplete"),
  config = {},
  current_job = nil,
  debounce_timer = nil,
  last_trigger_pos = nil,
}

-- Smart triggers for different languages
local triggers = {
  lua = { "function", "local", "if", "for", "while", "return", "require", ".", ":" },
  python = { "def", "class", "if", "for", "while", "return", "import", "from", ".", "(" },
  javascript = { "function", "const", "let", "if", "for", "while", "return", "import", ".", "(" },
  typescript = { "function", "const", "let", "if", "for", "while", "return", "import", "interface", "type", ".", "(" },
  go = { "func", "type", "var", "const", "if", "for", "return", "import", ".", "(" },
  rust = { "fn", "let", "mut", "if", "for", "while", "return", "use", "struct", "impl", ".", "::" },
  default = { ".", "(", "{", "=", " " },
}

-- Logging with noice.nvim
local function log(msg, level)
  if state.debug then
    vim.notify(msg, level or vim.log.levels.INFO, { title = "LLM TabComplete" })
  end
end

-- Clear all ghost text
local function clear_ghost()
  vim.api.nvim_buf_clear_namespace(0, state.ghost_ns, 0, -1)
end

-- Show multiple completion options
local function show_completions(completions, row, col)
  clear_ghost()
  if not completions or #completions == 0 then
    log("No completions to show")
    return
  end

  log(string.format("Showing %d completions at row %d, col %d", #completions, row, col))

  -- Show primary completion inline with better highlighting
  local primary = completions[1]
  if primary and primary.text then
    local lines = vim.split(primary.text, "\n")
    local first_line = lines[1] or ""

    log(string.format("Primary completion: '%s'", first_line))

    if first_line ~= "" then
      vim.api.nvim_buf_set_extmark(0, state.ghost_ns, row, col, {
        virt_text = { { first_line, "DiagnosticHint" } }, -- Changed from Comment to DiagnosticHint
        virt_text_pos = "inline",
      })
    end

    -- Show additional lines with better visibility
    for i = 2, #lines do
      if lines[i] and lines[i] ~= "" then
        vim.api.nvim_buf_set_extmark(0, state.ghost_ns, row + i - 1, 0, {
          virt_lines = { { { lines[i], "DiagnosticHint" } } },
          virt_lines_above = false,
        })
      end
    end
  end

  -- Show alternative options
  if #completions > 1 then
    local alt_text = {}
    for i = 2, math.min(#completions, 3) do -- Reduced to 3 alternatives
      local alt = completions[i]
      if alt and alt.text then
        local preview = alt.text:gsub("\n.*", ""):sub(1, 30) -- Shorter preview
        table.insert(alt_text, { string.format("[%d] %s", i, preview), "Comment" })
        if i < math.min(#completions, 3) then
          table.insert(alt_text, { " | ", "NonText" })
        end
      end
    end

    if #alt_text > 0 then
      vim.api.nvim_buf_set_extmark(0, state.ghost_ns, row + 1, 0, {
        virt_lines = { alt_text },
        virt_lines_above = false,
      })
    end
  end
end

-- Get cache key for context
local function get_cache_key(context)
  local key_parts = {
    context.filename,
    context.filetype,
    vim.fn.sha256(context.before_cursor:sub(-200)), -- Last 200 chars
    vim.fn.sha256(context.after_cursor:sub(1, 100)), -- First 100 chars
  }
  return table.concat(key_parts, "|")
end

-- Check if we should trigger completion
local function should_trigger()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]

  -- Skip if same position
  if state.last_trigger_pos and state.last_trigger_pos[1] == row and state.last_trigger_pos[2] == col then
    return false
  end

  local line = vim.api.nvim_get_current_line()
  local before_cursor = line:sub(1, col) -- Fix: use col instead of math.max(1, col - 20)
  local filetype = vim.bo.filetype

  local ft_triggers = triggers[filetype] or triggers.default

  -- Check triggers - look for recent trigger chars
  for _, trigger in ipairs(ft_triggers) do
    if before_cursor:match(vim.pesc(trigger) .. "[^" .. vim.pesc(trigger) .. "]*$") then
      log("Trigger found: " .. trigger)
      return true
    end
  end

  -- Trigger after typing (reduced from 5 to 3 chars)
  if col > 3 and before_cursor:match("%S{3,}$") then
    log("Length trigger activated")
    return true
  end

  return false
end

-- Enhanced context with FIM support
local function get_context()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]

  local filename = vim.api.nvim_buf_get_name(buf)
  local filetype = vim.bo.filetype

  -- Get 50 lines of context efficiently
  local start_line = math.max(0, row - 25)
  local end_line = math.min(vim.api.nvim_buf_line_count(buf) - 1, row + 25)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line + 1, false)

  -- Split at cursor position
  local cursor_line_idx = row - start_line + 1
  local current_line = lines[cursor_line_idx] or ""
  local line_before = current_line:sub(1, col)
  local line_after = current_line:sub(col + 1)

  -- Build before/after context
  local before_lines = vim.list_slice(lines, 1, cursor_line_idx - 1)
  table.insert(before_lines, line_before)
  local before_cursor = table.concat(before_lines, "\n")

  local after_lines = vim.list_slice(lines, cursor_line_idx + 1, #lines)
  local after_cursor = line_after
  if #after_lines > 0 then
    after_cursor = line_after .. "\n" .. table.concat(after_lines, "\n")
  end

  return {
    filename = vim.fn.fnamemodify(filename, ":t"),
    filetype = filetype,
    before_cursor = before_cursor,
    after_cursor = after_cursor,
    cursor_pos = { row = row, col = col },
  }
end

-- Build FIM completion prompt
local function build_completion_prompt(context)
  local system_prompt = string.format(
    [[You are a code completion AI. Complete the code at the <fim_middle> position.

CRITICAL RULES:
1. Return ONLY the completion text - no explanations, no quotes, no markdown
2. Complete what would naturally come next at the cursor position
3. Match existing indentation and style exactly
4. For %s: follow language conventions
5. Keep completions concise and practical

If multiple completions are possible, separate them with ||COMPLETION||

Context: %s file]],
    context.filetype,
    context.filetype
  )

  return string.format([[<fim_prefix>%s<fim_suffix>%s<fim_middle>]], context.before_cursor, context.after_cursor)
end

-- Fix 4: Better LLM command construction
local function get_completions(context, callback)
  local cache_key = get_cache_key(context)

  -- Check cache first
  if state.completion_cache[cache_key] then
    local cached = state.completion_cache[cache_key]
    local age = vim.loop.now() - cached.timestamp
    if age < 300000 then -- 5 minutes
      log("Using cached completion")
      callback(cached.completions)
      return
    else
      state.completion_cache[cache_key] = nil
    end
  end

  log("Requesting new completion from LLM")

  local args = { "prompt", "--no-stream" }

  if state.config.key then
    vim.list_extend(args, { "--key", state.config.key })
  end

  -- Improved system prompt
  local system_prompt = string.format(
    [[You are a code completion assistant. Complete code at <fim_middle> position.

Rules:
- Return ONLY completion text, no explanations
- Match existing code style and indentation  
- For %s files: follow language conventions
- Keep completions short and relevant
- Multiple options: separate with ||COMPLETION||

Complete what naturally comes next at cursor position.]],
    context.filetype
  )

  vim.list_extend(args, { "-s", system_prompt }) -- Remove shellescape

  -- Add config params
  for _, param in ipairs(state.config.params or {}) do
    vim.list_extend(args, { "-p", param[1], param[2] })
  end

  for _, opt in ipairs(state.config.options or {}) do
    vim.list_extend(args, { "-o", opt[1], opt[2] })
  end

  if state.config.template then
    vim.list_extend(args, { "-t", state.config.template })
  end

  local prompt = build_completion_prompt(context)
  table.insert(args, prompt) -- Remove shellescape

  log(string.format("LLM command: llm %s", table.concat(args, " ")))

  -- Cancel previous job
  if state.current_job then
    log("Cancelling previous job")
    vim.fn.jobstop(state.current_job)
  end

  state.current_job = vim.fn.jobstart({ "llm", unpack(args) }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 then
        local response = table.concat(data, "\n"):gsub("\n$", "")
        log(string.format("LLM response: '%s'", response:sub(1, 100)))

        if response ~= "" and not response:match("^%s*$") then
          -- Parse multiple completions
          local completions = {}
          local parts = vim.split(response, "||COMPLETION||", { plain = true })

          for i, part in ipairs(parts) do
            local trimmed = vim.trim(part)
            if trimmed ~= "" then
              table.insert(completions, {
                text = trimmed,
                priority = i == 1 and 100 or (100 - i * 10),
              })
            end
          end

          if #completions == 0 then
            table.insert(completions, { text = response, priority = 100 })
          end

          log(string.format("Parsed %d completions", #completions))

          -- Cache the results
          state.completion_cache[cache_key] = {
            completions = completions,
            timestamp = vim.loop.now(),
          }

          callback(completions)
        else
          log("Empty or whitespace-only response")
        end
      end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        local error_msg = table.concat(data, "\n")
        log("LLM error: " .. error_msg, vim.log.levels.ERROR)
      end
    end,
    on_exit = function(_, code)
      log(string.format("LLM job exited with code: %d", code))
      state.current_job = nil
    end,
  })
end

-- Request completions with smart debouncing
local function request_completions()
  if not should_trigger() then
    return
  end

  log("Starting completion request")

  if state.debounce_timer then
    vim.fn.timer_stop(state.debounce_timer)
  end

  state.debounce_timer = vim.fn.timer_start(100, function() -- Reduced from 200ms to 100ms
    local context = get_context()

    if #context.before_cursor < 5 then -- Reduced from 10 to 5
      log("Context too short, skipping")
      return
    end

    log(string.format("Context: %d chars before cursor", #context.before_cursor))
    state.last_trigger_pos = { context.cursor_pos.row, context.cursor_pos.col }

    get_completions(context, function(completions)
      vim.schedule(function()
        if vim.api.nvim_get_mode().mode == "i" then
          local cursor = vim.api.nvim_win_get_cursor(0)
          state.active_completions = completions
          show_completions(completions, cursor[1] - 1, cursor[2])
        else
          log("Not in insert mode, skipping completion display")
        end
      end)
    end)
  end)
end

-- Accept completion (with option to select alternative)
local function accept_completion(index)
  index = index or 1

  if not state.active_completions or not state.active_completions[index] then
    log(string.format("No completion at index %d", index))
    return false
  end

  log(string.format("Accepting completion %d: '%s'", index, state.active_completions[index].text:sub(1, 50)))

  clear_ghost()
  local completion = state.active_completions[index]
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local lines = vim.split(completion.text, "\n")

  -- Insert completion
  local current_line = vim.api.nvim_get_current_line()
  local new_line = current_line:sub(1, col) .. lines[1] .. current_line:sub(col + 1)
  vim.api.nvim_buf_set_lines(0, row, row + 1, false, { new_line })

  if #lines > 1 then
    vim.api.nvim_buf_set_lines(0, row + 1, row + 1, false, vim.list_slice(lines, 2))
  end

  -- Update cursor
  if #lines > 1 then
    vim.api.nvim_win_set_cursor(0, { row + #lines, #lines[#lines] })
  else
    vim.api.nvim_win_set_cursor(0, { row + 1, col + #lines[1] })
  end

  state.active_completions = {}
  state.last_trigger_pos = nil
  log("Completion accepted and applied")
  return true
end

-- Setup autocmds
local function setup_autocmds()
  local group = vim.api.nvim_create_augroup("LLMTabComplete", { clear = true })

  vim.api.nvim_create_autocmd({ "TextChangedI" }, {
    group = group,
    callback = function()
      if state.enabled then
        clear_ghost()
        request_completions()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMovedI" }, {
    group = group,
    callback = function()
      if state.enabled then
        clear_ghost()
        state.active_completions = {}
        state.last_trigger_pos = nil
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    callback = function()
      clear_ghost()
      state.active_completions = {}
      state.last_trigger_pos = nil
      if state.current_job then
        vim.fn.jobstop(state.current_job)
      end
    end,
  })
end

-- Setup keymaps with multi-completion support
local function setup_keymaps()
  vim.keymap.set("i", "<Tab>", function()
    if accept_completion(1) then
      return ""
    else
      return "<Tab>"
    end
  end, { expr = true, desc = "Accept primary LLM completion" })

  -- Alternative completions
  for i = 2, 4 do
    vim.keymap.set("i", "<C-" .. i .. ">", function()
      accept_completion(i)
      return ""
    end, { expr = true, desc = "Accept completion option " .. i })
  end

  vim.keymap.set("i", "<C-]>", function()
    clear_ghost()
    state.active_completions = {}
    state.last_trigger_pos = nil
  end, { desc = "Dismiss completions" })
end

function M.enable(config)
  state.config = vim.deepcopy(config or {})
  state.enabled = true
  state.debug = true
  state.completion_cache = {}
  log("Tab completion enabled")
  setup_autocmds()
  setup_keymaps()
end

function M.disable()
  log("Tab completion disabled")
  state.enabled = false
  clear_ghost()

  if state.debounce_timer then
    vim.fn.timer_stop(state.debounce_timer)
    state.debounce_timer = nil
  end

  if state.current_job then
    vim.fn.jobstop(state.current_job)
    state.current_job = nil
  end

  state.active_completions = {}
  state.completion_cache = {}
  state.last_trigger_pos = nil
end

function M.toggle(config)
  if state.enabled then
    M.disable()
  else
    M.enable(config)
  end
end

function M.is_enabled()
  return state.enabled
end

function M.clear_cache()
  log("Clearing completion cache")
  state.completion_cache = {}
end

function M.set_debug(enabled)
  state.debug = enabled
  log(string.format("Debug logging %s", enabled and "enabled" or "disabled"))
end

return M
