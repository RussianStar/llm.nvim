local M = {}

local vim = vim or {} -- Ensure the `vim` global is available
local curl = require('plenary.curl')
local telescope = require('telescope')
local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local actions = require('telescope.actions')
local previewers = require('telescope.previewers')
local action_state = require('telescope.actions.state')
local conf = require('telescope.config').values
local Job = require 'plenary.job'

local timeout_ms = 10000

local service_lookup = {
	groq = {
		url = "https://api.groq.com/openai/v1/chat/completions",
		model = "llama3-70b-8192",
		api_key_name = "GROQ_API_KEY",
	},
	openai = {
		url = "https://api.openai.com/v1/chat/completions",
		model = "gpt-4o",
		api_key_name = "OPENAI_API_KEY",
	},
	anthropic = {
		url = "https://api.anthropic.com/v1/messages",
		model = "claude-3-5-sonnet-20240620",
		api_key_name = "ANTHROPIC_API_KEY",
	},
}

local function get_api_key(name)
	return os.getenv(name)
end

-- I want this test function to get from the lsp all function definitions and print them
function M.test()
-- Ensure vim and lsp_util are available
local vim = vim
local lsp_util = require('vim.lsp.util')

-- Function to print the current type of file and the used lsp
local function print_filetype_and_lsp()
    -- Get the current buffer number
    local bufnr = vim.api.nvim_get_current_buf()

    -- Get the file type of the current buffer
    local filetype = vim.api.nvim_buf_get_option(bufnr, 'filetype')
    
    -- Initialize a variable to hold active LSP clients
    local active_lsps = {}

    -- Iterate through all attached LSP clients and collect their names
    for _, client in pairs(vim.lsp.get_active_clients({bufnr = bufnr})) do
        table.insert(active_lsps, client.name)
    end

    -- Print the file type
    print("Filetype: " .. filetype)

    -- Print the active LSP clients or a message if none are found
    if #active_lsps > 0 then
        print("Active LSPs: " .. table.concat(active_lsps, ", "))
    else
        print("No active LSP clients found.")
    end
end

print_filetype_and_lsp()

local function get_symbols()
    local params = { textDocument = vim.lsp.util.make_text_document_params() }
    local result = vim.lsp.buf_request_sync(0, 'textDocument/documentSymbol', params, 1000)
    if not result or vim.tbl_isempty(result) then
        print("No symbols found")
        return
    end

local symbols = {}
local function flatten_symbols(symbols_table, flattened)
    for _, symbol in ipairs(symbols_table) do
        table.insert(flattened, symbol)
        if symbol.children then
            flatten_symbols(symbol.children, flattened)
        end
    end
end

-- Flatten the tree structure into a single list of symbols
local flattened_symbols = {}
for _, res in pairs(result) do
    if res.result then
        flatten_symbols(res.result, flattened_symbols)
    end
end

if #flattened_symbols == 0 then
    print("No symbols found")
    return
end

for _, symbol in ipairs(flattened_symbols) do
if symbol.kind == 12 or symbol.kind == 6 then 
    local name = symbol.name
    local start_line = symbol.range.start.line + 1
    local start_char = symbol.range.start.character + 1

    local buffer = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buffer, start_line - 1, start_line, false)
    if #lines == 0 then
        print("No lines found for the function")
        return
    end

local func_signature = ""  
local buffer = vim.api.nvim_get_current_buf()  
local lines = vim.api.nvim_buf_get_lines(buffer, start_line - 1, start_line, false)
local i = 1  
local signatureFinished = false

while true do
    local line = lines[1]
    while i <= #line do
        local char = line:sub(i, i)
        if char == '{' then  
							signatureFinished = true
            break
        end
        func_signature = func_signature .. char
        i = i + 1
    end

    if signatureFinished then
        break
    end

    start_line = start_line + 1
    lines = vim.api.nvim_buf_get_lines(buffer, start_line - 1, start_line, false)
    if #lines == 0 then
        break
    end
    i = 1
end
    print(string.format("Function: %s", func_signature))
end
end
end
	get_symbols()
end

function M.setup(opts)
	timeout_ms = opts.timeout_ms or timeout_ms
	if opts.services then
		for key, service in pairs(opts.services) do
			service_lookup[key] = service
		end
	end
end


local curl = require('plenary.curl')
local finders = require('telescope.finders')
local pickers = require('telescope.pickers')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')


function M.async_fetch_models(callback)
  curl.get('https://openrouter.ai/api/v1/models', {
    callback = vim.schedule_wrap(function(response)
      if response.status ~= 200 then
        print('Failed to fetch models')
        callback({})
      else
        -- Using pcall to safely decode JSON
        local success, data = pcall(vim.json.decode, response.body)
        if not success or type(data) ~= 'table' then
          print('Invalid data received')
          callback({})
        else
          callback(data.data)
        end
      end
    end)
  })
end



function M.pick_model()
  M.async_fetch_models(function(models)
    pickers.new({}, {
      prompt_title = 'Select a Model',
      finder = finders.new_table {
        results = models,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.name or entry.id,
            ordinal = entry.name or entry.id,
            metadata = entry
          }
        end,
      },
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
define_preview = function(self, entry, status)
  local bufnr = self.state.bufnr
  local model = entry.metadata

  local function sanitize(str)
    return str:gsub("\n", " ")
  end

  local function pretty_json(obj)
    local json_str = vim.fn.json_encode(obj)
    local pretty_str = vim.fn.system('python -m json.tool', json_str)
    return pretty_str
  end

  local content = vim.split(pretty_json(model), '\n')

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
end
      }),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          M.model = selection.value.id 
        end)
        return true
      end,
    }):find()
  end)
end

function M.get_lines_until_cursor()
	local current_buffer = vim.api.nvim_get_current_buf()
	local current_window = vim.api.nvim_get_current_win()
	local cursor_position = vim.api.nvim_win_get_cursor(current_window)
	local row = cursor_position[1]

	local lines = vim.api.nvim_buf_get_lines(current_buffer, 0, row, true)

	return table.concat(lines, "\n")
end

local function write_string_at_cursor(str)
	local current_window = vim.api.nvim_get_current_win()
	local cursor_position = vim.api.nvim_win_get_cursor(current_window)
	local row, col = cursor_position[1], cursor_position[2]

	local lines = vim.split(str, "\n")
	vim.api.nvim_put(lines, "c", true, true)

	local num_lines = #lines
	local last_line_length = #lines[num_lines]
	vim.api.nvim_win_set_cursor(current_window, { row + num_lines - 1, col + last_line_length })
end

local function process_data_lines(buffer, process_data)
	local has_line_terminators = buffer:find("\r") or buffer:find("\n")

	local lines = {}
	for line in buffer:gmatch("(.-)\r?\n") do
		table.insert(lines, line)
	end

	if #lines == 0 then
		for line in buffer:gmatch("[^\n]+") do
			table.insert(lines, line)
		end
	end

	buffer = buffer:sub(#table.concat(lines, "\n") + 1)
	for _, line in ipairs(lines) do
		local data_start = line:find("data: ")
		if data_start then
			local json_str = line:sub(data_start + 6)
			local stop = false
			if line == "data: [DONE]" then
				return true
			end
			local data = vim.json.decode(json_str)
			if service == "anthropic" then
				stop = data.type == "message_stop"
			end
				local stop
				if line == "data: [DONE]" then
					return true
				end
				local data = vim.json.decode(json_str)
				if "anthropic" then
					stop = data.type == "message_stop"
				end
				if stop then
					return true
				else
					vim.defer_fn(function()
						process_data(data)
						vim.cmd("undojoin")
					end, 5)
				end
		end
	end
end


local function prepare_request(opts)
	local replace = opts.replace
	local service = opts.service
	local visual_lines = M.get_visual_selection()
	local system_prompt = [[
You are an AI programming assistant integrated into a code editor. Your purpose is to help the user with programming tasks as they write code.
Key capabilities:
- Thoroughly analyze the user's code and provide insightful suggestions for improvements related to best practices, performance, readability, and maintainability. Explain your reasoning.
- Answer coding questions in detail, using examples from the user's own code when relevant. Break down complex topics step-by-step.
- Spot potential bugs and logical errors. Alert the user and suggest fixes.
- Upon request, add helpful comments explaining complex or unclear code.
- Suggest relevant documentation, StackOverflow answers, and other resources related to the user's code and questions.
- Engage in back-and-forth conversations to understand the user's intent and provide the most helpful information.
- Keep concise and use markdown.
- When asked to create code, only generate the code. No bugs.
- Think step by step
    ]]

	if visual_lines then
		prompt = table.concat(visual_lines, "\n")
		if replace then
			system_prompt =
			"Follow the instructions in the code comments. Generate code only. Think step by step. If you must speak, do so in comments. Generate valid code only."
			vim.api.nvim_command("normal! d")
			vim.api.nvim_command("normal! k")
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)
		end
	else
		prompt = M.get_lines_until_cursor()
	end

	local found_service = service_lookup[service]
	if not found_service then
		print("Invalid service: " .. service)
		return nil
	end

	local url = found_service.url
	local model = M.model
	local api_key_name = found_service.api_key_name
	local api_key = api_key_name and get_api_key(api_key_name)

	local data = {
		messages = {
			{
				role = "system",
				content = system_prompt,
			},
			{
				role = "user",
				content = prompt,
			},
		},
		model = model,
		stream = true,
	}

	if service == "anthropic" then
		data.max_tokens = 1024
	else
		data.temperature = 0.7
	end

	local args = {
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-d",
		vim.json.encode(data)
	}

	if api_key then
		local header_auth = service == "anthropic" and "x-api-key: " .. api_key or
		"Authorization: Bearer " .. api_key
		table.insert(args, "-H")
		table.insert(args, header_auth)
		if service == "anthropic" then
			table.insert(args, "-H")
			table.insert(args, "anthropic-version: 2023-06-01")
		end
	end

	table.insert(args, url)
	return args
end

function M.prompt(opts)
	local args = prepare_request(opts)
	if not args then
		print("Failed to prepare request.")
		return
	end
	vim.api.nvim_command("normal! o")
	vim.api.nvim_command('undojoin')
	Job:new({
		command = 'curl',
		args = args,
		on_stdout = function(err, buffer)
			if err then
				print("Error:", err)
			else
				process_data_lines(buffer, function(data)
					local content
					if service == "anthropic" then
						if data.delta and data.delta.text then
							content = data.delta.text
						end
					else
						if data.choices and data.choices[1] and data.choices[1].delta then
							content = data.choices[1].delta.content
						end
					end
					if content and content ~= vim.NIL then
						has_tokens = true
						vim.api.nvim_command('undojoin')
						write_string_at_cursor(content)
					end
				end)
			end
		end,
		on_exit = function(j, return_val)
			if return_val ~= 0 then
				print("Curl command failed with code:", return_val)
			end
		end,
	}):start()
end

function M.get_visual_selection()
	local _, srow, scol = unpack(vim.fn.getpos("v"))
	local _, erow, ecol = unpack(vim.fn.getpos("."))

	-- visual line mode
	if vim.fn.mode() == "V" then
		if srow > erow then
			return vim.api.nvim_buf_get_lines(0, erow - 1, srow, true)
		else
			return vim.api.nvim_buf_get_lines(0, srow - 1, erow, true)
		end
	end

	-- regular visual mode
	if vim.fn.mode() == "v" then
		if srow < erow or (srow == erow and scol <= ecol) then
			return vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, ecol, {})
		else
			return vim.api.nvim_buf_get_text(0, erow - 1, ecol - 1, srow - 1, scol, {})
		end
	end

	-- visual block mode
	if vim.fn.mode() == "\22" then
		local lines = {}
		if srow > erow then
			srow, erow = erow, srow
		end
		if scol > ecol then
			scol, ecol = ecol, scol
		end
		for i = srow, erow do
			table.insert(
				lines,
				vim.api.nvim_buf_get_text(0, i - 1, math.min(scol - 1, ecol), i - 1,
					math.max(scol - 1, ecol), {})[1]
			)
		end
		return lines
	end
end

function M.create_llm_md()
	local cwd = vim.fn.getcwd()
	local cur_buf = vim.api.nvim_get_current_buf()
	local cur_buf_name = vim.api.nvim_buf_get_name(cur_buf)
	local llm_md_path = cwd .. "/llm.md"
	if cur_buf_name ~= llm_md_path then
		vim.api.nvim_command("edit " .. llm_md_path)
		local buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
		vim.api.nvim_win_set_buf(0, buf)
	end
end

return M

