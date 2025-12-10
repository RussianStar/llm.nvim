local llm = require('llm')
local nio = require('nio')

describe('provider routing', function()
  local orig_run
  local orig_process_run
  local orig_system
  local orig_apply_response

  before_each(function()
    orig_run = nio.run
    orig_process_run = nio.process.run
    orig_system = vim.system
    orig_apply_response = require('llm.diff').apply_response
  end)

  after_each(function()
    nio.run = orig_run
    nio.process.run = orig_process_run
    vim.system = orig_system
    require('llm.diff').apply_response = orig_apply_response
  end)

  it('routes prompt configuration to the configured provider', function()
    local payload_args
    local curl_args

    local adapter = {
      build_chat_payload = function(args)
        payload_args = args
        return {
          model = args.model,
          system = args.system_prompt,
          user = args.user_prompt,
          stream = args.stream,
          extra = args.extra_params and args.extra_params.extra_field,
        }
      end,
      extract_stream_content = function() end,
    }

    llm.setup({
      services = {
        test_provider = {
          url = 'https://example.test/chat',
          model = 'custom-model',
          api_key_name = 'TEST_KEY',
          adapter = adapter,
          headers = { ['X-Test'] = 'abc' },
          stream_params = { extra_field = 'stream-value' },
        },
      },
    })

    vim.env.TEST_KEY = 'secret-token'

    local fake_response = {
      stdout = { read = function() return nil end, close = function() end },
      stderr = { read = function() return nil end },
    }

    nio.process.run = function(opts)
      curl_args = opts.args
      return fake_response
    end

    nio.run = function(fn)
      fn()
    end

    vim.api.nvim_command('enew')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'example buffer text' })

    llm.prompt({ service = 'test_provider' })

    assert.are_same('custom-model', payload_args.model)
    assert.are_same('stream-value', payload_args.extra_params.extra_field)

    local payload_json
    for i, arg in ipairs(curl_args) do
      if arg == '-d' then
        payload_json = curl_args[i + 1]
      end
    end

    assert.truthy(payload_json)
    local decoded = vim.json.decode(payload_json)
    assert.are_same('stream-value', decoded.extra)
    assert.are_same('custom-model', decoded.model)

    assert.is_true(vim.tbl_contains(curl_args, 'Authorization: Bearer secret-token'))
    assert.is_true(vim.tbl_contains(curl_args, 'X-Test: abc'))
    assert.equals('https://example.test/chat', curl_args[#curl_args])
  end)

  it('routes edit configuration to the configured provider', function()
    local payload_args
    local curl_args

    local adapter = {
      build_chat_payload = function(args)
        payload_args = args
        return {
          model = args.model,
          edit = args.user_prompt,
          params = args.extra_params,
        }
      end,
      extract_message_content = function(message)
        return message and message.content
      end,
    }

    llm.setup({
      services = {
        edit_provider = {
          url = 'https://example.test/edit',
          model = 'edit-model',
          api_key_name = 'EDIT_KEY',
          adapter = adapter,
          headers = { ['X-Edit'] = '123' },
          edit_params = { temperature = 0.2 },
        },
      },
    })

    vim.env.EDIT_KEY = 'edit-token'

    vim.system = function(args)
      curl_args = args
      return {
        wait = function()
          return {
            code = 0,
            stdout = vim.json.encode({
              choices = {
                { message = { content = 'diff content' } },
              },
            }),
            stderr = '',
          }
        end,
      }
    end

    require('llm.diff').apply_response = function()
      return true
    end

    local ok, err = llm.edit({
      service = 'edit_provider',
      prompt = 'Edit this',
      context = 'ctx',
      files = { 'file.txt' },
      apply = false,
    })

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are_same('edit-model', payload_args.model)
    assert.are_same(0.2, payload_args.extra_params.temperature)

    local payload_json
    for i, arg in ipairs(curl_args) do
      if arg == '-d' then
        payload_json = curl_args[i + 1]
      end
    end

    assert.truthy(payload_json)
    local decoded = vim.json.decode(payload_json)
    assert.are_same(0.2, decoded.params.temperature)
    assert.are_same('edit-model', decoded.model)

    assert.is_true(vim.tbl_contains(curl_args, 'Authorization: Bearer edit-token'))
    assert.is_true(vim.tbl_contains(curl_args, 'X-Edit: 123'))
    assert.equals('https://example.test/edit', curl_args[#curl_args])
  end)
end)
