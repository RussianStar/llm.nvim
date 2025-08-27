local M = {}

local entries = {}

local function estimate_tokens(text)
  return math.ceil(#text / 4)
end

function M.clear()
  entries = {}
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

return M

