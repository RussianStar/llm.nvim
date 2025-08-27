local context = require('llm.context')

describe('context helpers', function()
  before_each(function()
    context.clear()
  end)

  it('collects buffer and manual context', function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      'hello',
      'world',
    })

    local symbols = { { result = { { name = 'MySymbol' } } } }
    local orig = vim.lsp.buf_request_sync
    vim.lsp.buf_request_sync = function() return symbols end

    context.add_context_file(bufnr)

    vim.lsp.buf_request_sync = orig

    context.add_context('extra text', 'Extra')

    local entries = context.get_context_entries()

    assert.equals('hello\nworld', entries[1].text)
    assert.equals('MySymbol', entries[1].symbol)
    assert.equals(math.ceil(#('hello\nworld') / 4), entries[1].tokens)

    assert.equals('extra text', entries[2].text)
    assert.equals('Extra', entries[2].symbol)
    assert.equals(math.ceil(#('extra text') / 4), entries[2].tokens)
  end)
end)
