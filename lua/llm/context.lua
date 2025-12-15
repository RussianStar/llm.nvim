local M = {}

local entries = {}
local context_paths = {}

-- Build a concise list of symbols using LSP documentSymbol
local function lsp_symbols(bufnr, timeout)
  timeout = timeout or 800
  local ok, result = pcall(vim.lsp.buf_request_sync, bufnr, "textDocument/documentSymbol", nil, timeout)
  if not ok or type(result) ~= "table" then
    return {}
  end
  local symbols = {}
  for _, res in pairs(result) do
    if res and res.result then
      for _, item in ipairs(res.result) do
        if item.name then
          table.insert(symbols, item.name)
        end
        if item.children then
          for _, child in ipairs(item.children) do
            if child.name then
              table.insert(symbols, child.name)
            end
          end
        end
      end
    end
  end
  return symbols
end

local function estimate_tokens(text)
  return math.ceil(#text / 4)
end

function M.clear()
  entries = {}
  context_paths = {}
end

function M.get_context_entries()
  return entries
end

function M.add_context(text, symbol)
  table.insert(entries, {
    text = text,
    symbol = symbol or "",
    tokens = estimate_tokens(text),
  })
end

function M.add_context_file(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  local symbols = {}
  local ok, result = pcall(vim.lsp.buf_request_sync, bufnr, "textDocument/documentSymbol", nil, 1000)
  if ok and type(result) == "table" then
    for _, res in pairs(result) do
      if res.result then
        for _, item in ipairs(res.result) do
          if item.name then
            table.insert(symbols, item.name)
          end
        end
      end
    end
  end
  local symbol_str = table.concat(symbols, ", ")
  table.insert(entries, {
    text = text,
    symbol = symbol_str,
    tokens = estimate_tokens(text),
  })
end

-- Add an arbitrary file path with optional label/note
function M.add_context_path(path, note, max_bytes)
  max_bytes = max_bytes or 12000
  local fd = io.open(path, "r")
  if not fd then
    return false, "cannot open file: " .. path
  end
  local data = fd:read(max_bytes)
  fd:close()
  if not data then
    return false, "empty file"
  end
  local rel = vim.fn.fnamemodify(path, ":.")
  local label = note or rel
  M.add_context(string.format("file: %s\n```\n%s\n```", rel, data), label)
  table.insert(context_paths, { path = rel, note = note, max_bytes = max_bytes })
  return true
end

local function rebuild_entries()
  entries = {}
  for _, item in ipairs(context_paths) do
    local _ = M.add_context_path(item.path, item.note, item.max_bytes)
  end
end

function M.remove_context_path(rel)
  local new_paths = {}
  for _, item in ipairs(context_paths) do
    if item.path ~= rel then
      table.insert(new_paths, item)
    end
  end
  context_paths = new_paths
  rebuild_entries()
end

-- Build a compact context string from stored entries
function M.get_extra_context_string(max_chars)
  max_chars = max_chars or 16000
  local parts, total = {}, 0
  for _, e in ipairs(entries) do
    local txt = e.text or ""
    if total + #txt <= max_chars then
      table.insert(parts, txt)
      total = total + #txt
    end
  end
  return table.concat(parts, "\n\n")
end

-- Build default inline context for the current buffer (symbols, optional diagnostics later)
function M.build_default_context(bufnr, opts)
  opts = opts or {}
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local symbols = {}
  if opts.include_symbols ~= false then
    symbols = lsp_symbols(bufnr, opts.symbol_timeout or 800)
  end
  local sym_str = ""
  if #symbols > 0 then
    local max = opts.max_symbols or 40
    local list = {}
    for i, name in ipairs(symbols) do
      if i > max then break end
      table.insert(list, name)
    end
    sym_str = "Symbols: " .. table.concat(list, ", ")
  end
  local extra = {}
  if sym_str ~= "" then
    table.insert(extra, sym_str)
  end
  return table.concat(extra, "\n")
end

local function parse_line(line)
  local trimmed = vim.trim(line)
  if trimmed == "" then
    return nil
  end
  local path, note = trimmed:match("^([^|]+)|%s*(.+)$")
  if not path then
    path = trimmed
  end
  path = vim.fn.fnamemodify(vim.trim(path), ":.")
  note = note and vim.trim(note) or nil
  return { path = path, note = note }
end

function M.open_context_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "llm://context")
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "llmcontext"

  local lines = {}
  for _, item in ipairs(context_paths) do
    if item.note then
      table.insert(lines, string.format("%s | %s", item.path, item.note))
    else
      table.insert(lines, item.path)
    end
  end
  if #lines == 0 then
    lines = { "# Add one file path per line. Optional: path | note" }
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      context_paths = {}
      for _, l in ipairs(new_lines) do
        if not l:match("^%s*#") then
          local parsed = parse_line(l)
          if parsed then
            table.insert(context_paths, parsed)
          end
        end
      end
      rebuild_entries()
      print("llm.nvim: context list updated (" .. #context_paths .. " files)")
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })

  -- floating window centered
  local width = math.floor(vim.o.columns * 0.45)
  local height = 12
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = row,
    col = col,
  })
end

function M.pick_context_files()
  local ok = pcall(require, "telescope")
  if not ok then
    print("llm.nvim: telescope.nvim is required for context picking")
    return
  end
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "Add context files",
      finder = finders.new_oneshot_job({ "rg", "--files" }, {}),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _)
        local function add_selected()
          local picker = action_state.get_current_picker(prompt_bufnr)
          local selections = picker:get_multi_selection()
          if #selections == 0 then
            local entry = action_state.get_selected_entry()
            if entry then
              selections = { entry }
            end
          end
          actions.close(prompt_bufnr)
          for _, sel in ipairs(selections) do
            local path = sel.path or sel.value or sel[1]
            if path then
              M.add_context_path(path)
            end
          end
          print("llm.nvim: added " .. tostring(#selections) .. " context file(s)")
        end
        actions.select_default:replace(add_selected)
        actions.toggle_selection:enhance({ post = false })
        return true
      end,
    })
    :find()
end

function M.add_current_buffer(max_bytes)
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    print("llm.nvim: current buffer has no file name")
    return
  end
  local ok, err = M.add_context_path(path, nil, max_bytes)
  if not ok then
    print("llm.nvim: " .. err)
  else
    print("llm.nvim: added context file " .. vim.fn.fnamemodify(path, ":."))
  end
end

return M
