-- ask.lua
local M = {}

-- State
local state = {
  buf = nil,
  win = nil,
  config = {},
  last_files = {},
  last_prompt = "",
}

-- Get responsive window dimensions
local function get_dimensions()
  local width = math.max(math.floor(vim.o.columns * 0.8), 80)
  local height = math.floor(vim.o.lines * 0.7)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 3)
  return width, height, row, col
end

-- Build llm prompt command arguments
local function build_args(cfg, files, user_prompt, continue)
  local args = { "prompt" }

  if cfg.system_prompt then
    vim.list_extend(args, { "-s", vim.fn.shellescape(cfg.system_prompt) })
  end
  if cfg.template then
    vim.list_extend(args, { "-t", vim.fn.shellescape(cfg.template) })
  end
  for _, param in ipairs(cfg.params or {}) do
    vim.list_extend(args, { "-p", unpack(vim.tbl_map(vim.fn.shellescape, param)) })
  end
  for _, opt in ipairs(cfg.options or {}) do
    vim.list_extend(args, { "-o", unpack(vim.tbl_map(vim.fn.shellescape, opt)) })
  end
  if cfg.no_stream then
    table.insert(args, "--no-stream")
  end
  if cfg.key then
    vim.list_extend(args, { "--key", vim.fn.shellescape(cfg.key) })
  end
  for _, file in ipairs(files) do
    vim.list_extend(args, { "-f", file })
  end
  if continue then
    table.insert(args, "--continue")
  end
  if user_prompt then
    table.insert(args, vim.fn.shellescape(user_prompt))
  end

  -- TODO: REMOVE
  vim.list_extend(args, { "-o", "unlimited", "1" })
  return args
end

-- Execute llm prompt and display output
local function execute_prompt(files, user_prompt, continue)
  if not files or #files == 0 then
    vim.notify("No valid files selected", vim.log.levels.ERROR)
    return
  end
  if not user_prompt or user_prompt == "" then
    vim.notify("No prompt provided", vim.log.levels.ERROR)
    return
  end

  -- Store last files and prompt for reuse
  state.last_files = files
  state.last_prompt = user_prompt

  local args = build_args(state.config, files, user_prompt, continue)

  local output_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(output_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(output_buf, "filetype", "markdown")

  local width, height, row, col = get_dimensions()
  local output_win = vim.api.nvim_open_win(output_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    title = "LLM Prompt Output",
    title_pos = "center",
  })

  vim.api.nvim_buf_set_option(output_buf, "wrap", true)
  vim.api.nvim_win_set_option(output_win, "wrap", true)
  vim.api.nvim_win_set_option(output_win, "linebreak", true)
  vim.api.nvim_win_set_option(output_win, "breakindent", true)

  -- Initialize with "Processing..." message
  vim.api.nvim_buf_set_option(output_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { "Processing..." })

  -- Use stdin/stdout pipes for streaming
  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local line_buffer = ""

  -- Spawn LLM command as an async process
  local handle = vim.loop.spawn("llm", {
    args = args,
    stdio = { nil, stdout, stderr },
  }, function(code)
    -- On process exit
    if code ~= 0 then
      vim.schedule(function()
        vim.notify("Command exited with code " .. code, vim.log.levels.ERROR)
      end)
    end

    -- Close pipes
    stdout:close()
    stderr:close()
  end)

  -- Function to append content to buffer
  local function append_lines(lines)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(output_buf) then
        vim.api.nvim_buf_set_option(output_buf, "modifiable", true)

        -- Clear "Processing..." on first output
        local current_lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
        if #current_lines == 1 and current_lines[1] == "Processing..." then
          vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, lines)
        else
          vim.api.nvim_buf_set_lines(output_buf, -1, -1, false, lines)
        end

        vim.api.nvim_buf_set_option(output_buf, "modifiable", false)
      end
    end)
  end

  -- Process stdout stream
  stdout:read_start(function(err, chunk)
    if err then
      append_lines({ "Error: " .. err })
    elseif chunk then
      line_buffer = line_buffer .. chunk
      local lines = {}
      local last_newline = 0

      for i = 1, #line_buffer do
        if line_buffer:sub(i, i) == "\n" then
          local line = line_buffer:sub(last_newline + 1, i - 1)
          table.insert(lines, line)
          last_newline = i
        end
      end

      line_buffer = line_buffer:sub(last_newline + 1)
      if #lines > 0 then
        append_lines(lines)
      end
    end
  end)

  -- Process stderr stream
  stderr:read_start(function(err, chunk)
    if err then
      -- Split error string by newlines
      local error_lines = {}
      for line in err:gmatch("[^\n]+") do
        table.insert(error_lines, line)
      end
      append_lines(error_lines)
    elseif chunk then
      -- Split error chunk by newlines
      local error_lines = {}
      for line in chunk:gmatch("[^\n]+") do
        table.insert(error_lines, line)
      end
      append_lines(error_lines)
    end
  end)

  -- Keybindings for closing and other actions
  vim.keymap.set("n", "q", function()
    if handle then
      handle:close()
    end
    vim.api.nvim_win_close(output_win, true)
  end, { buffer = output_buf })

  vim.keymap.set("n", "<Esc>", function()
    if handle then
      handle:close()
    end
    vim.api.nvim_win_close(output_win, true)
  end, { buffer = output_buf })

  -- New keybinding: 'n' for new prompt with same fragments
  vim.keymap.set("n", "n", function()
    if handle then
      handle:close()
    end
    vim.api.nvim_win_close(output_win, true)

    vim.ui.input({ prompt = "Enter your question: " }, function(input)
      if input and input ~= "" then
        execute_prompt(state.last_files, input, false)
      end
    end)
  end, { buffer = output_buf })

  -- New keybinding: 'c' for continue with same fragments
  vim.keymap.set("n", "c", function()
    if handle then
      handle:close()
    end
    vim.api.nvim_win_close(output_win, true)

    vim.ui.input({ prompt = "Enter your follow-up question: " }, function(input)
      if input and input ~= "" then
        execute_prompt(state.last_files, input, true)
      end
    end)
  end, { buffer = output_buf })

  -- New keybinding: 's' for save prompt with template name
  vim.keymap.set("n", "s", function()
    vim.ui.input({ prompt = "Save prompt with template name: " }, function(template_name)
      if template_name and template_name ~= "" then
        local save_args = { "prompt", "--save", template_name }
        if user_prompt then
          table.insert(save_args, vim.fn.shellescape(user_prompt))
        end

        vim.fn.system("llm " .. table.concat(save_args, " "))
        vim.notify("Prompt saved as template: " .. template_name, vim.log.levels.INFO)
      end
    end)
  end, { buffer = output_buf })
end

-- Open the ask menu
local function open_ask_menu()
  local current_file = vim.api.nvim_buf_get_name(0)
  local open_files = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and name ~= "" and vim.fn.filereadable(name) == 1 then
      table.insert(open_files, name)
    end
  end

  -- Prepare menu content
  local content = {
    "LLM Ask Menu",
    "───────────",
    "",
    "[1] Current file: " .. (current_file ~= "" and vim.fn.fnamemodify(current_file, ":t") or "[No file]"),
    "[2] All open files: " .. #open_files .. " file(s)",
    "[3] Scratch buffer content",
    "[4] Current git repository changes (diff)",
    "[5] Select a git commit (diff)",
    "[6] Current branch vs master (diff)",
    "",
    "Select an option or press 'q'/'Esc' to cancel",
  }

  -- Create buffer and window
  local width, height, row, col = get_dimensions()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(state.buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(state.buf, "filetype", "llm-ask")

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    title = "LLM Ask",
    title_pos = "center",
  })

  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, content)
  vim.api.nvim_buf_set_option(state.buf, "modifiable", false)
  vim.api.nvim_win_set_option(state.win, "cursorline", true)

  -- Keybindings
  vim.keymap.set("n", "1", function()
    if current_file == "" or vim.fn.filereadable(current_file) == 0 then
      vim.notify("No valid current file selected", vim.log.levels.WARN)
      return
    end
    vim.api.nvim_win_close(state.win, true)
    state.win = nil
    state.buf = nil
    vim.ui.input({ prompt = "Enter your question: " }, function(input)
      if input and input ~= "" then
        execute_prompt({ current_file }, input, false)
      end
    end)
  end, { buffer = state.buf })

  vim.keymap.set("n", "2", function()
    if #open_files == 0 then
      vim.notify("No valid open files found", vim.log.levels.WARN)
      return
    end
    vim.api.nvim_win_close(state.win, true)
    state.win = nil
    state.buf = nil
    vim.ui.input({ prompt = "Enter your question: " }, function(input)
      if input and input ~= "" then
        execute_prompt(open_files, input, false)
      end
    end)
  end, { buffer = state.buf })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(state.win, true)
    state.win = nil
    state.buf = nil
  end, { buffer = state.buf })

  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(state.win, true)
    state.win = nil
    state.buf = nil
  end, { buffer = state.buf })

  -- Add keybinding for option "3" (snacks.nvim scratch buffer)
  vim.keymap.set("n", "3", function()
    -- Get list of snacks.nvim scratch buffers
    local scratch_files = require("snacks").scratch.list()
    if not scratch_files or #scratch_files == 0 then
      vim.notify("No snacks.nvim scratch buffers found", vim.log.levels.WARN)
      return
    end

    -- Calculate maximum widths for each column (cwd, icon, name, branch)
    local widths = { 0, 0, 0, 0 } -- [cwd, icon, name, branch]
    local items = {}
    for i, scratch in ipairs(scratch_files) do
      -- Assign or compute icon
      local icon = scratch.icon or require("snacks").util.icon(scratch.ft, "filetype")
      -- Format cwd and branch
      local cwd = scratch.cwd and vim.fn.fnamemodify(scratch.cwd, ":p:~") or ""
      local branch = scratch.branch and ("branch:%s"):format(scratch.branch) or ""
      -- Store item for selection
      items[i] = {
        scratch = scratch,
        display = { cwd, icon, scratch.name, branch },
      }
      -- Update maximum widths
      widths[1] = math.max(widths[1], vim.api.nvim_strwidth(cwd))
      widths[2] = math.max(widths[2], vim.api.nvim_strwidth(icon))
      widths[3] = math.max(widths[3], vim.api.nvim_strwidth(scratch.name))
      widths[4] = math.max(widths[4], vim.api.nvim_strwidth(branch))
    end

    -- Prompt user to select a scratch buffer
    vim.ui.select(items, {
      prompt = "Select Scratch Buffer",
      format_item = function(item)
        local parts = {}
        for i, part in ipairs(item.display) do
          parts[i] = part .. string.rep(" ", widths[i] - vim.api.nvim_strwidth(part))
        end
        return table.concat(parts, " ")
      end,
    }, function(choice)
      if not choice then
        return
      end

      local selected_scratch = choice.scratch
      local scratch_file = selected_scratch.file

      -- Verify the scratch file exists and is readable
      if vim.fn.filereadable(scratch_file) == 0 then
        vim.notify("Selected scratch buffer file is not readable", vim.log.levels.WARN)
        return
      end

      -- Read the content to ensure it's not empty
      local scratch_content = vim.fn.readfile(scratch_file)
      if #scratch_content == 0 or (#scratch_content == 1 and scratch_content[1] == "") then
        vim.notify("Selected scratch buffer is empty", vim.log.levels.WARN)
        return
      end

      -- Close the menu
      vim.api.nvim_win_close(state.win, true)
      state.win = nil
      state.buf = nil

      -- Prompt for user input
      vim.ui.input({ prompt = "Enter your question: " }, function(input)
        if input and input ~= "" then
          -- Pass the scratch file directly to execute_prompt
          execute_prompt({ scratch_file }, input, false)
        end
      end)
    end)
  end, { buffer = state.buf })

  -- Option 4: Current git repository changes (diff)
  vim.keymap.set("n", "4", function()
    local temp_file = vim.fn.tempname()
    -- Run separate commands for staged, unstaged, and untracked diffs
    local commands = {
      "git diff --cached", -- Staged changes
      "git diff", -- Unstaged changes
      "git ls-files --others --exclude-standard | xargs -I {} git diff /dev/null {}", -- Untracked files
    }
    local diff_output = {}
    local success = true
    for _, cmd in ipairs(commands) do
      local result = vim.fn.system(cmd)
      if vim.v.shell_error ~= 0 then
        success = false
        vim.notify("Error running '" .. cmd .. "': " .. result, vim.log.levels.ERROR)
      elseif result and result ~= "" then
        -- Split result into lines and add to diff_output
        for line in result:gmatch("[^\r\n]+") do
          table.insert(diff_output, line)
        end
      end
    end
    if not success or #diff_output == 0 then
      vim.notify("No git changes found or error occurred", vim.log.levels.WARN)
      return
    end
    -- Write diff lines to temp file
    vim.fn.writefile(diff_output, temp_file)
    vim.api.nvim_win_close(state.win, true)
    state.win = nil
    state.buf = nil
    vim.ui.input({ prompt = "Enter your question: " }, function(input)
      if input and input ~= "" then
        execute_prompt({ temp_file }, input, false)
      else
        vim.fn.delete(temp_file)
      end
    end)
  end, { buffer = state.buf }) -- Option 5:
  vim.keymap.set("n", "5", function()
    -- Use vim.fn.system for simpler git log execution
    local log_output = vim.fn.system("git log --oneline -n 50")
    if vim.v.shell_error ~= 0 then
      vim.notify("Failed to get git log: " .. log_output, vim.log.levels.ERROR)
      return
    end
    local commits = {}
    for line in log_output:gmatch("[^\r\n]+") do
      local hash, message = line:match("^(%S+)%s+(.+)$")
      if hash and message then
        table.insert(commits, { hash = hash, message = message })
      end
    end
    if #commits == 0 then
      vim.notify("No commits found", vim.log.levels.WARN)
      return
    end
    vim.ui.select(commits, {
      prompt = "Select a commit",
      format_item = function(item)
        return item.hash .. " " .. item.message
      end,
    }, function(choice)
      if not choice then
        return
      end
      local temp_file = vim.fn.tempname()
      local diff_result = vim.fn.system("git diff " .. choice.hash .. "^ " .. choice.hash .. " > " .. temp_file)
      if vim.v.shell_error ~= 0 then
        vim.notify("Failed to get diff for commit " .. choice.hash .. ": " .. diff_result, vim.log.levels.ERROR)
        vim.fn.delete(temp_file)
        return
      end
      local diff_content = vim.fn.readfile(temp_file)
      if #diff_content == 0 then
        vim.notify("No changes in selected commit", vim.log.levels.WARN)
        vim.fn.delete(temp_file)
        return
      end
      vim.api.nvim_win_close(state.win, true)
      state.win = nil
      state.buf = nil
      vim.ui.input({ prompt = "Enter your question: " }, function(input)
        if input and input ~= "" then
          execute_prompt({ temp_file }, input, false)
        else
          vim.fn.delete(temp_file)
        end
      end)
    end)
  end, { buffer = state.buf })

  -- Option 6: Current branch vs master (diff)
  vim.keymap.set("n", "6", function()
    local current_branch = vim.fn.system("git rev-parse --abbrev-ref HEAD"):gsub("\n", "")
    if current_branch == "" or current_branch == "master" then
      vim.notify("Not on a valid branch or on master", vim.log.levels.WARN)
      return
    end
    local temp_file = vim.fn.tempname()
    vim.fn.system("git diff master..." .. current_branch .. " > " .. temp_file)
    local diff_content = vim.fn.readfile(temp_file)
    if #diff_content == 0 then
      vim.notify("No differences found between " .. current_branch .. " and master", vim.log.levels.WARN)
      vim.fn.delete(temp_file)
      return
    end
    vim.api.nvim_win_close(state.win, true)
    state.win = nil
    state.buf = nil
    vim.ui.input({ prompt = "Enter your question: " }, function(input)
      if input and input ~= "" then
        execute_prompt({ temp_file }, input, false)
      else
        vim.fn.delete(temp_file)
      end
    end)
  end, { buffer = state.buf })
end

function M.start_ask(config)
  state.config = vim.deepcopy(config)
  open_ask_menu()
end

return M
