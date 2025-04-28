-- fragments.lua

local M = {}

-- State
local state = {
  buf = nil,
  win = nil,
  fragments = {},
  aliases = {},
  search_term = "",
  selected_fragments = {},
}

-- Get responsive window dimensions
local function get_dimensions()
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.7)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  return width, height, row, col
end

-- Parse fragment output
local function parse_fragments_output(output)
  local fragments = {}
  local current_fragment = nil

  for _, line in ipairs(output) do
    if line:match("^%- hash:") then
      -- Start a new fragment
      if current_fragment then
        table.insert(fragments, current_fragment)
      end
      local hash = line:match("^%- hash:%s*(.+)$")
      current_fragment = {
        hash = hash,
        aliases = {},
        content = "",
        datetime = "",
        source = "",
        display = line,
      }
    elseif current_fragment then
      if line:match("^%s+aliases:") then
        local aliases_str = line:match("^%s+aliases:%s*(.*)$")
        if aliases_str and aliases_str ~= "[]" then
          for alias in aliases_str:gmatch("'([^']+)'") do
            table.insert(current_fragment.aliases, alias)
          end
        end
      elseif line:match("^%s+datetime_utc:") then
        current_fragment.datetime = line:match("^%s+datetime_utc:%s*'(.+)'$") or ""
      elseif line:match("^%s+source:") then
        current_fragment.source = line:match("^%s+source:%s*(.+)$") or ""
      elseif line:match("^%s+content:") then
        -- Start of content block
        current_fragment.content_preview = line:match("^%s+content:%s*(.+)$") or ""
      else
        -- Assume it's part of the content
        if current_fragment.content ~= "" then
          current_fragment.content = current_fragment.content .. "\n" .. line
        else
          current_fragment.content = line
        end
      end
    end
  end

  -- Add the last fragment
  if current_fragment then
    table.insert(fragments, current_fragment)
  end

  return fragments
end

-- Load fragments from llm command
local function load_fragments(search_term)
  local cmd = "llm fragments list"
  if search_term and search_term ~= "" then
    cmd = cmd .. " -q " .. vim.fn.shellescape(search_term)
  end

  local output = vim.fn.systemlist(cmd)
  state.fragments = parse_fragments_output(output)

  -- Load aliases separately
  local aliases_output = vim.fn.systemlist("llm fragments list --aliases")
  state.aliases = parse_fragments_output(aliases_output)
end

-- Set alias for a fragment
local function set_fragment_alias(alias, fragment)
  local cmd = "llm fragments set " .. vim.fn.shellescape(alias) .. " " .. vim.fn.shellescape(fragment)
  local output = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to set alias: " .. output, vim.log.levels.ERROR)
    return false
  end

  vim.notify("Alias '" .. alias .. "' set for fragment", vim.log.levels.INFO)
  return true
end

-- Remove fragment alias
local function remove_fragment_alias(alias)
  local cmd = "llm fragments remove " .. vim.fn.shellescape(alias)
  local output = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to remove alias: " .. output, vim.log.levels.ERROR)
    return false
  end

  vim.notify("Alias '" .. alias .. "' removed", vim.log.levels.INFO)
  return true
end

-- Show fragment content
local function show_fragment_content(alias_or_hash)
  local cmd = "llm fragments show " .. vim.fn.shellescape(alias_or_hash)
  local output = vim.fn.systemlist(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to show fragment: " .. table.concat(output, "\n"), vim.log.levels.ERROR)
    return nil
  end

  return output
end

-- Add current buffer as fragment
local function add_buffer_as_fragment(buf_id, alias)
  local temp_file = vim.fn.tempname()
  local lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)

  -- Write buffer content to temp file
  local file = io.open(temp_file, "w")
  if not file then
    vim.notify("Failed to create temporary file", vim.log.levels.ERROR)
    return false
  end

  file:write(table.concat(lines, "\n"))
  file:close()

  -- Add the fragment
  local success = set_fragment_alias(alias, temp_file)

  -- Clean up
  os.remove(temp_file)
  return success
end

-- Add all open buffers as fragments
local function add_all_buffers_as_fragments(prefix)
  local count = 0

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_option(buf, "modified") == false then
      local name = vim.api.nvim_buf_get_name(buf)
      if name and name ~= "" then
        local basename = vim.fn.fnamemodify(name, ":t:r")
        local alias = prefix .. basename

        if add_buffer_as_fragment(buf, alias) then
          count = count + 1
        end
      end
    end
  end

  vim.notify("Added " .. count .. " buffers as fragments", vim.log.levels.INFO)
  return count > 0
end

-- Find files using grep and add as fragments
local function grep_files_as_fragments(pattern, prefix)
  local cmd = "grep -l " .. vim.fn.shellescape(pattern) .. " * --include='*.lua' --include='*.md' --include='*.txt' -r"
  local output = vim.fn.systemlist(cmd)

  if vim.v.shell_error > 1 then -- grep returns 1 if no matches
    vim.notify("Grep failed: " .. table.concat(output, "\n"), vim.log.levels.ERROR)
    return false
  end

  local count = 0
  for _, file in ipairs(output) do
    local basename = vim.fn.fnamemodify(file, ":t:r")
    local alias = prefix .. basename

    if set_fragment_alias(alias, file) then
      count = count + 1
    end
  end

  vim.notify("Added " .. count .. " files as fragments", vim.log.levels.INFO)
  return count > 0
end

-- Create the fragments window
function M.start_fragments_manager(config)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  -- Load fragments
  load_fragments("")

  -- Prepare content for display
  local content = {
    "LLM FRAGMENTS MANAGER",
    "────────────────────",
    "",
    "Actions:",
    "  [a] Add current buffer as fragment",
    "  [A] Add all buffers as fragments",
    "  [g] Find files with grep and add as fragments",
    "  [r] Remove alias",
    "  [s] Show fragment content",
    "  [/] Search fragments",
    "",
    "Available fragments (press Enter to copy hash/alias to clipboard):",
    "───────────────────────────────────────────────────────────────",
    "",
  }

  -- Add fragments to content
  for _, fragment in ipairs(state.fragments) do
    -- Format aliases
    local alias_str = ""
    if #fragment.aliases > 0 then
      alias_str = " (aliases: " .. table.concat(fragment.aliases, ", ") .. ")"
    end

    -- Format source
    local source_str = ""
    if fragment.source and fragment.source ~= "" then
      source_str = " from " .. fragment.source
    end

    -- Format preview
    local preview = fragment.content_preview or ""
    if #preview > 50 then
      preview = preview:sub(1, 47) .. "..."
    end

    table.insert(content, fragment.hash:sub(1, 10) .. "..." .. alias_str .. source_str)
    if preview ~= "" then
      table.insert(content, "  " .. preview)
    end
    table.insert(content, "")
  end

  table.insert(content, "Press 'q' or <Esc> to close this window")

  -- Create buffer and window
  local width, height, row, col = get_dimensions()
  state.buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_option(state.buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(state.buf, "filetype", "llm-fragments")

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    title = "LLM Fragments Manager",
    title_pos = "center",
  })

  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, content)
  vim.api.nvim_buf_set_option(state.buf, "modifiable", false)
  vim.api.nvim_win_set_option(state.win, "cursorline", true)

  -- Highlight aliases in special color
  local ns_id = vim.api.nvim_create_namespace("llm_fragments")
  for i, line in ipairs(content) do
    if line:match("%(aliases:") then
      vim.api.nvim_buf_add_highlight(state.buf, ns_id, "DiffAdd", i - 1, 0, -1)
    end
  end

  -- Set up key mappings
  vim.api.nvim_buf_set_keymap(state.buf, "n", "<CR>", "", {
    callback = function()
      local cursor = vim.api.nvim_win_get_cursor(state.win)
      local line_num = cursor[1]
      local line = vim.api.nvim_buf_get_lines(state.buf, line_num - 1, line_num, false)[1]

      -- Try to extract hash or alias from the line
      local hash = line:match("^([a-f0-9]+)%.%.%.")
      local alias = line:match("%(aliases:%s*([^,%)]+)")

      if hash or alias then
        local value = alias or hash
        vim.fn.setreg("+", value)
        vim.notify("Copied '" .. value .. "' to clipboard", vim.log.levels.INFO)
      end
    end,
    noremap = true,
    silent = true,
  })

  -- Add current buffer as fragment
  vim.api.nvim_buf_set_keymap(state.buf, "n", "a", "", {
    callback = function()
      vim.ui.input({ prompt = "Alias for current buffer:" }, function(alias)
        if alias and alias ~= "" then
          local current_buf = vim.api.nvim_get_current_buf()
          if add_buffer_as_fragment(current_buf, alias) then
            M.close()
            M.start_fragments_manager(config)
          end
        end
      end)
    end,
    noremap = true,
    silent = true,
  })

  -- Add all buffers as fragments
  vim.api.nvim_buf_set_keymap(state.buf, "n", "A", "", {
    callback = function()
      vim.ui.input({ prompt = "Prefix for buffer aliases:" }, function(prefix)
        if prefix and prefix ~= "" then
          if add_all_buffers_as_fragments(prefix) then
            M.close()
            M.start_fragments_manager(config)
          end
        end
      end)
    end,
    noremap = true,
    silent = true,
  })

  -- Find files with grep and add as fragments
  vim.api.nvim_buf_set_keymap(state.buf, "n", "g", "", {
    callback = function()
      vim.ui.input({ prompt = "Grep pattern:" }, function(pattern)
        if pattern and pattern ~= "" then
          vim.ui.input({ prompt = "Prefix for aliases:" }, function(prefix)
            if prefix and prefix ~= "" then
              if grep_files_as_fragments(pattern, prefix) then
                M.close()
                M.start_fragments_manager(config)
              end
            end
          end)
        end
      end)
    end,
    noremap = true,
    silent = true,
  })

  -- Remove alias
  vim.api.nvim_buf_set_keymap(state.buf, "n", "r", "", {
    callback = function()
      vim.ui.input({ prompt = "Alias to remove:" }, function(alias)
        if alias and alias ~= "" then
          if remove_fragment_alias(alias) then
            M.close()
            M.start_fragments_manager(config)
          end
        end
      end)
    end,
    noremap = true,
    silent = true,
  })

  -- Show fragment content
  vim.api.nvim_buf_set_keymap(state.buf, "n", "s", "", {
    callback = function()
      vim.ui.input({ prompt = "Alias or hash to show:" }, function(alias_or_hash)
        if alias_or_hash and alias_or_hash ~= "" then
          local content = show_fragment_content(alias_or_hash)
          if content then
            -- Create a new buffer to show the content
            local content_buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_option(content_buf, "bufhidden", "wipe")
            vim.api.nvim_buf_set_lines(content_buf, 0, -1, false, content)

            -- Create content window
            local width, height, row, col = get_dimensions()
            local content_win = vim.api.nvim_open_win(content_buf, true, {
              relative = "editor",
              width = width,
              height = height,
              row = row,
              col = col,
              border = "rounded",
              title = "Fragment: " .. alias_or_hash,
              title_pos = "center",
            })

            -- Close on q or Esc
            vim.api.nvim_buf_set_keymap(content_buf, "n", "q", "", {
              callback = function()
                vim.api.nvim_win_close(content_win, true)
                vim.api.nvim_set_current_win(state.win)
              end,
              noremap = true,
              silent = true,
            })
            vim.api.nvim_buf_set_keymap(content_buf, "n", "<Esc>", "", {
              callback = function()
                vim.api.nvim_win_close(content_win, true)
                vim.api.nvim_set_current_win(state.win)
              end,
              noremap = true,
              silent = true,
            })
          end
        end
      end)
    end,
    noremap = true,
    silent = true,
  })

  -- Search fragments
  vim.api.nvim_buf_set_keymap(state.buf, "n", "/", "", {
    callback = function()
      vim.ui.input({ prompt = "Search term:" }, function(term)
        if term then
          state.search_term = term
          M.close()
          M.start_fragments_manager(config)
        end
      end)
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
end

-- Close the fragments window
function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
end

return M
