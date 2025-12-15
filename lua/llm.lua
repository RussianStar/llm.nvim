local nio = require("nio")
local diff = require("llm.diff")
local M = {}

local timeout_ms = 10000

local default_openai_adapter = {
        build_chat_payload = function(args)
                local data = {
                        messages = {
                                {
                                        role = "system",
                                        content = args.system_prompt,
                                },
                                {
                                        role = "user",
                                        content = args.user_prompt,
                                },
                        },
                        model = args.model,
                        stream = args.stream,
                        temperature = args.temperature or 0.7,
                }

                if args.extra_params then
                        for key, value in pairs(args.extra_params) do
                                data[key] = value
                        end
                end

                return data
        end,
        extract_stream_content = function(data, opts)
                opts = opts or {}
                local delta = data.choices and data.choices[1] and data.choices[1].delta
                if not delta then
                        return nil
                end

                local content = delta.content
                if type(content) == "table" then
                        local chunks = {}
                        for _, part in ipairs(content) do
                                if part.type == "reasoning" and opts.trim_thinking then
                                        goto continue
                                end
                                if part.type == "text" and part.text then
                                        table.insert(chunks, part.text)
                                end
                                ::continue::
                        end
                        return table.concat(chunks, "")
                end

                if type(content) == "string" then
                        if opts.trim_thinking then
                                return content:gsub("<think>[%s%S]-</think>", "")
                        end
                        return content
                end

                return nil
        end,
        extract_message_content = function(message, opts)
                opts = opts or {}
                local content = message and message.content
                if type(content) == "table" then
                        local parts = {}
                        for _, item in ipairs(content) do
                                if item.type == "reasoning" and opts.trim_thinking then
                                        goto continue
                                end
                                if item.type == "text" and item.text then
                                        table.insert(parts, item.text)
                                end
                                ::continue::
                        end
                        return table.concat(parts, "")
                elseif type(content) == "string" then
                        if opts.trim_thinking then
                                return content:gsub("<think>[%s%S]-</think>", "")
                        end
                        return content
                end
                return ""
        end,
}

-- Track streaming processes so they can be cancelled independently
local current_responses = {}

-- Namespace for extmarks used when streaming results
local ns = vim.api.nvim_create_namespace("llm")

-- Remove unwanted characters from streamed content
local function sanitize_content(content)
        -- Strip various unicode multiplication symbols and similar characters
        return content:gsub("[×✕✖✗✘]", "")
end

local function add_custom_headers(args, headers)
        if not headers then
                return
        end
        for name, value in pairs(headers) do
                table.insert(args, "-H")
                table.insert(args, string.format("%s: %s", name, value))
        end
end

-- Display messages when hitting provider limits
local function check_limits(data, service)
        if service == "anthropic" then
                if data.stop_reason == "max_tokens" then
                        print("llm.nvim: token limit reached")
                end
        else
                if data.choices and data.choices[1] and data.choices[1].finish_reason == "length" then
                        print("llm.nvim: token limit reached")
                end
        end
end

local anthropic_adapter = {
        build_chat_payload = function(args)
                local data = {
                        system = args.system_prompt,
                        messages = {
                                {
                                        role = "user",
                                        content = args.user_prompt,
                                },
                        },
                        model = args.model,
                        stream = args.stream,
                        max_tokens = args.max_tokens or 1024,
                }

                if args.extra_params then
                        for key, value in pairs(args.extra_params) do
                                data[key] = value
                        end
                end

                return data
        end,
        extract_stream_content = function(data)
                if data.delta and data.delta.text then
                        return data.delta.text
                end
                return nil
        end,
        extract_message_content = function(message)
                local content = message and message[1]
                if type(content) == "table" and content.text then
                        return content.text
                end
                return ""
        end,
}

local service_lookup = {
        groq = {
                url = "https://api.groq.com/openai/v1/chat/completions",
                model = "llama3-70b-8192",
                api_key_name = "GROQ_API_KEY",
                adapter = default_openai_adapter,
        },
        openai = {
                url = "https://api.openai.com/v1/chat/completions",
                model = "gpt-4o",
                api_key_name = "OPENAI_API_KEY",
                adapter = default_openai_adapter,
        },
        openrouter = {
                url = "https://openrouter.ai/api/v1/chat/completions",
                model = "gpt-4o-mini",
                api_key_name = "OPENROUTER_API_KEY",
                adapter = default_openai_adapter,
                trim_thinking = true,
        },
        anthropic = {
                url = "https://api.anthropic.com/v1/messages",
                model = "claude-3-5-sonnet-20240620",
                api_key_name = "ANTHROPIC_API_KEY",
                adapter = anthropic_adapter,
        },
}

local function get_api_key(name)
        return os.getenv(name)
end

local function get_service(name)
        local service = service_lookup[name]
        if not service then
                print("llm.nvim: unknown service '" .. name .. "'")
                return nil
        end

        return service
end

function M.setup(opts)
        timeout_ms = opts.timeout_ms or timeout_ms
        if opts.services then
                for key, service in pairs(opts.services) do
                        if not service.adapter then
                                service.adapter = default_openai_adapter
                        end
                        service_lookup[key] = service
                end
        end
end

local function fetch_openrouter_models()
        local service = get_service("openrouter")
        if not service then
                return nil
        end

        local api_key_name = service.api_key_name or "OPENROUTER_API_KEY"
        local api_key = get_api_key(api_key_name)
        if not api_key then
                print("llm.nvim: missing env var '" .. api_key_name .. "' for OpenRouter")
                return nil
        end

        local args = {
                "-sS",
                "-H",
                "Authorization: Bearer " .. api_key,
        }

        add_custom_headers(args, service.headers)

        table.insert(args, "https://openrouter.ai/api/v1/models")

        local result = vim.system({ "curl", unpack(args) }, { text = true }):wait()
        if result.code ~= 0 then
                print("llm.nvim: failed to fetch models from OpenRouter")
                return nil
        end

        local ok, data = pcall(vim.json.decode, result.stdout)
        if not ok or not data or not data.data then
                print("llm.nvim: unable to parse OpenRouter models list")
                return nil
        end

        return data.data
end

local function pick_openrouter_model()
        local ok = pcall(require, "telescope")
        if not ok then
                print("llm.nvim: telescope.nvim is required for model selection")
                return
        end

        local models = fetch_openrouter_models()
        if not models or vim.tbl_isempty(models) then
                return
        end

        local pickers = require("telescope.pickers")
        local finders = require("telescope.finders")
        local conf = require("telescope.config").values
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")

        local entries = {}
        for _, item in ipairs(models) do
                local id = item.id or item.name
                if id then
                        table.insert(entries, {
                                value = id,
                                display = item.name and string.format("%s - %s", id, item.name) or id,
                                ordinal = string.format("%s %s", id, item.name or ""),
                        })
                end
        end

        if vim.tbl_isempty(entries) then
                print("llm.nvim: no models returned by OpenRouter")
                return
        end

        pickers
                .new({}, {
                        prompt_title = "OpenRouter Models",
                        finder = finders.new_table({
                                results = entries,
                                entry_maker = function(entry)
                                        return {
                                                value = entry.value,
                                                display = entry.display,
                                                ordinal = entry.ordinal,
                                        }
                                end,
                        }),
                        sorter = conf.generic_sorter({}),
                        attach_mappings = function(prompt_bufnr, map)
                                local function set_model()
                                        local selection = action_state.get_selected_entry()
                                        actions.close(prompt_bufnr)
                                        if not selection or not selection.value then
                                                return
                                        end

                                        local service = get_service("openrouter")
                                        if not service then
                                                return
                                        end

                                        service.model = selection.value
                                        print("llm.nvim: OpenRouter model set to " .. selection.value)
                                end

                                actions.select_default:replace(set_model)
                                return true
                        end,
                })
                :find()
end

function M.get_lines_until_cursor()
	local current_buffer = vim.api.nvim_get_current_buf()
	local current_window = vim.api.nvim_get_current_win()
	local cursor_position = vim.api.nvim_win_get_cursor(current_window)
	local row = cursor_position[1]

	local lines = vim.api.nvim_buf_get_lines(current_buffer, 0, row, true)

	return table.concat(lines, "\n")
end

local function write_at_mark(ctx, str)
        local buf, mark = ctx.buf, ctx.mark
        -- Get current position of the extmark
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
        if not pos or #pos == 0 then
                return
        end
        local row, col = pos[1], pos[2]
        local lines = vim.split(str, "\n")
        vim.api.nvim_buf_call(buf, function()
                pcall(vim.cmd, "undojoin")
                vim.api.nvim_buf_set_text(buf, row, col, row, col, lines)
        end)

        local last_line = lines[#lines]
        local new_row = row + #lines - 1
        local new_col = #lines == 1 and col + #last_line or #last_line
        vim.api.nvim_buf_set_extmark(buf, ns, new_row, new_col, { id = mark })
end

local function process_data_lines(lines, service, ctx, process_data)
        for _, line in ipairs(lines) do
                local data_start = line:find("data: ")
                if data_start then
                        local json_str = line:sub(data_start + 6)
                        local stop = false
                        if line == "data: [DONE]" then
                                return true
                        end
                        local ok, data = pcall(vim.json.decode, json_str)
                        if not ok then
                                print("llm.nvim: failed to parse response")
                                return true
                        end
                        if data.error then
                                print("llm.nvim error: " .. (data.error.message or vim.inspect(data.error)))
                                return true
                        end
                        if service == "anthropic" then
                                stop = data.type == "message_stop"
                        end
                        if stop then
                                check_limits(data, service)
                                return true
                        else
                                nio.sleep(5)
                                vim.schedule(function()
                                        vim.api.nvim_buf_call(ctx.buf, function()
                                                pcall(vim.cmd, "undojoin")
                                                process_data(data)
                                        end)
                                end)
                        end
                end
        end
        return false
end

local function process_sse_response(ctx, service)
        local response = ctx.response
        local buffer = ""
        local has_tokens = false
        local start_time = vim.uv.hrtime()
        current_responses[response] = ctx

        nio.run(function()
                nio.sleep(timeout_ms)
                if current_responses[response] and not has_tokens then
                        response.stdout.close()
                        if response.kill then
                                response:kill()
                        end
                        current_responses[response] = nil
                        print("llm.nvim has timed out!")
                end
        end)
        local done = false
        while not done do
                local current_time = vim.uv.hrtime()
                local elapsed = (current_time - start_time)
                if elapsed >= timeout_ms * 1000000 and not has_tokens then
                        return
                end
                local chunk = response.stdout.read(1024)
                local err_chunk = response.stderr.read(1024)
                if err_chunk and #err_chunk > 0 then
                        print("llm.nvim error: " .. err_chunk)
                        break
                end
                if chunk == nil then
                        break
                end
                buffer = buffer .. chunk

		local lines = {}
		for line in buffer:gmatch("(.-)\r?\n") do
			table.insert(lines, line)
		end

		buffer = buffer:sub(#table.concat(lines, "\n") + 1)

                done = process_data_lines(lines, service, ctx, function(data)
                        local content
                        if ctx.adapter and ctx.adapter.extract_stream_content then
                                content = ctx.adapter.extract_stream_content(data, { trim_thinking = ctx.trim_thinking })
                        end
                        if content and content ~= vim.NIL and content ~= "" then
                                content = sanitize_content(content)
                                has_tokens = true
                                write_at_mark(ctx, content)
                        end
                end)
        end
        current_responses[response] = nil
end

function M.prompt(opts)
	local replace = opts.replace
	local service = opts.service
	local prompt = ""
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

        local url = ""
        local model = ""
        local api_key_name = ""
        local adapter
        local trim_thinking = opts.trim_thinking
        local stream_params

        local found_service = service_lookup[service]
        if found_service then
                url = found_service.url
                api_key_name = found_service.api_key_name
                model = found_service.model
                adapter = found_service.adapter
                stream_params = found_service.stream_params
                if trim_thinking == nil then
                        trim_thinking = found_service.trim_thinking
                end
        else
                print("Invalid service: " .. service)
                return
        end

        adapter = adapter or default_openai_adapter
        trim_thinking = trim_thinking or false

        local api_key = api_key_name and get_api_key(api_key_name)

        local data
        data = adapter.build_chat_payload({
                system_prompt = system_prompt,
                user_prompt = prompt,
                model = model,
                stream = true,
                temperature = 0.7,
                max_tokens = 1024,
                extra_params = stream_params,
        })

        local args = {
                "-sS",
                "-N",
                "-X",
                "POST",
                "-H",
                "Content-Type: application/json",
                "-d",
                vim.json.encode(data),
        }

        add_custom_headers(args, found_service.headers)

        if api_key then
                if service == "anthropic" then
                        table.insert(args, "-H")
			table.insert(args, "x-api-key: " .. api_key)
			table.insert(args, "-H")
			table.insert(args, "anthropic-version: 2023-06-01")
		else
			table.insert(args, "-H")
			table.insert(args, "Authorization: Bearer " .. api_key)
		end
	end

        table.insert(args, url)

        -- capture buffer and position for streaming
        local buf = vim.api.nvim_get_current_buf()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        -- insert a new line where output will be written
        vim.api.nvim_buf_set_lines(buf, row, row, true, { "" })
        local mark = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {})

        local response = nio.process.run({
                cmd = "curl",
                args = args,
        })
        local ctx = { buf = buf, mark = mark, response = response, adapter = adapter, trim_thinking = trim_thinking }
        nio.run(function()
                process_sse_response(ctx, service)
        end)
end

function M.edit(opts)
        opts = opts or {}
        local files = opts.files or { vim.api.nvim_buf_get_name(0) }
        local service = opts.service
        local instruction = opts.prompt or ""

        local service_info = service_lookup[service]
        if not service_info then
                print("Invalid service: " .. tostring(service))
                return false, "invalid service"
        end

        local rel_files, context_str
        if opts.context then
                context_str = opts.context
                rel_files = {}
                for _, file in ipairs(files) do
                        table.insert(rel_files, vim.fn.fnamemodify(file, ":."))
                end
        else
                local contexts = {}
                rel_files = {}
                for _, file in ipairs(files) do
                        local rel = vim.fn.fnamemodify(file, ":.")
                        table.insert(rel_files, rel)
                        local lines = vim.fn.readfile(file)
                        table.insert(contexts, string.format("file: %s\n```\n%s\n```", rel, table.concat(lines, "\n")))
                end
                context_str = table.concat(contexts, "\n\n")
        end
        local user_prompt = instruction
                .. "\n\n"
                .. context_str
                .. "\nRespond with unified diffs in blocks like ```diff file=path```"
        if opts.allow_new_files then
                user_prompt = user_prompt .. "\nYou may include blocks for new files."
        end

        local api_key = get_api_key(service_info.api_key_name)
        local adapter = service_info.adapter or default_openai_adapter
        local trim_thinking = opts.trim_thinking
        if trim_thinking == nil then
                trim_thinking = service_info.trim_thinking
        end
        trim_thinking = trim_thinking or false

        local data = adapter.build_chat_payload({
                system_prompt = "You are an AI code editor that returns patches.",
                user_prompt = user_prompt,
                model = service_info.model,
                stream = false,
                temperature = 0,
                max_tokens = service_info.max_tokens or 1024,
                extra_params = service_info.edit_params,
        })

        local args = {
                "-s",
                "-X",
                "POST",
                "-H",
                "Content-Type: application/json",
                "-d",
                vim.json.encode(data),
        }

        add_custom_headers(args, service_info.headers)

        if api_key then
                if service == "anthropic" then
                        table.insert(args, "-H")
                        table.insert(args, "x-api-key: " .. api_key)
                        table.insert(args, "-H")
                        table.insert(args, "anthropic-version: 2023-06-01")
                else
                        table.insert(args, "-H")
                        table.insert(args, "Authorization: Bearer " .. api_key)
                end
        end

        table.insert(args, service_info.url)

        local result = vim.system({ "curl", unpack(args) }, { text = true }):wait()
        if result.code ~= 0 then
                return false, result.stderr
        end

        local body = result.stdout
        local ok, parsed = pcall(vim.json.decode, body)
        if not ok then
                return false, "invalid json"
        end
        if parsed.error then
                return false, parsed.error.message or parsed.error
        end

        local response
        if service == "anthropic" then
                response = adapter.extract_message_content(parsed.content, { trim_thinking = trim_thinking })
        else
                response = adapter.extract_message_content(
                        parsed.choices and parsed.choices[1] and parsed.choices[1].message,
                        { trim_thinking = trim_thinking }
                )
        end

        local apply = opts.apply or false
        local success, err = diff.apply_response(response, {
                retry = opts.retry,
                dry_run = not apply,
                allow_new_files = opts.allow_new_files,
                files = rel_files,
        })
        if not success then
                print("llm.nvim: " .. err)
                return false, err
        end
        return true
end

function M.cancel()
        local cancelled = false
        for _, ctx in pairs(current_responses) do
                ctx.response.stdout.close()
                if ctx.response.kill then
                        ctx.response:kill()
                end
                cancelled = true
        end
        current_responses = {}
        if cancelled then
                print("llm.nvim request cancelled")
        else
                print("llm.nvim: no active request")
        end
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
				vim.api.nvim_buf_get_text(0, i - 1, math.min(scol - 1, ecol), i - 1, math.max(scol - 1, ecol), {})[1]
			)
		end
		return lines
        end
end

local function estimate_tokens(text)
        return math.ceil(#text / 4)
end

local function has_tiktoken()
        if vim.fn.executable("python3") ~= 1 then
                return false
        end
        vim.fn.system({ "python3", "-c", "import tiktoken" })
        return vim.v.shell_error == 0
end

local function count_file_tokens(path, use_tiktoken)
        if use_tiktoken then
                local py = "import sys, tiktoken, codecs; text = codecs.open(sys.argv[1], 'r', encoding='utf-8', errors='ignore').read(); enc = tiktoken.get_encoding('cl100k_base'); print(len(enc.encode(text)))"
                local out = vim.fn.system({ "python3", "-c", py, path })
                if vim.v.shell_error == 0 then
                        local n = tonumber(out)
                        if n then
                                return n
                        end
                end
        end

        local ok, lines = pcall(vim.fn.readfile, path)
        if ok then
                return estimate_tokens(table.concat(lines, "\n"))
        end
        return 0
end

function M.token_count()
        local root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
        if vim.v.shell_error ~= 0 or not root or root == "" then
                print("llm.nvim: not a git repository")
                return 0
        end

        local cmd = string.format("git -C %s ls-files", vim.fn.shellescape(root))
        local files = vim.fn.systemlist(cmd)

        local use_tiktoken = has_tiktoken()
        local total = 0
        for _, file in ipairs(files) do
                total = total + count_file_tokens(root .. "/" .. file, use_tiktoken)
        end

        local msg = use_tiktoken and "token count" or "estimated token count"
        print("llm.nvim: " .. msg .. " " .. total)
        return total
end

vim.api.nvim_create_user_command("LLMTokenCount", function()
        M.token_count()
end, {})

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

M.pick_openrouter_model = pick_openrouter_model

return M
