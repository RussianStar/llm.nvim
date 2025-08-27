local nio = require("nio")
local diff = require("llm.diff")
local M = {}

local timeout_ms = 10000

-- Track streaming processes so they can be cancelled independently
local current_responses = {}

-- Namespace for extmarks used when streaming results
local ns = vim.api.nvim_create_namespace("llm")

-- Remove unwanted characters from streamed content
local function sanitize_content(content)
        -- Strip various unicode multiplication symbols and similar characters
        return content:gsub("[×✕✖✗✘]", "")
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

function M.setup(opts)
	timeout_ms = opts.timeout_ms or timeout_ms
	if opts.services then
		for key, service in pairs(opts.services) do
			service_lookup[key] = service
		end
	end
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

	local found_service = service_lookup[service]
	if found_service then
		url = found_service.url
		api_key_name = found_service.api_key_name
		model = found_service.model
	else
		print("Invalid service: " .. service)
		return
	end

	local api_key = api_key_name and get_api_key(api_key_name)

	local data
	if service == "anthropic" then
		data = {
			system = system_prompt,
			messages = {
				{
					role = "user",
					content = prompt,
				},
			},
			model = model,
			stream = true,
			max_tokens = 1024,
		}
	else
		data = {
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
			temperature = 0.7,
			stream = true,
		}
	end

	local args = {
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-d",
		vim.json.encode(data),
	}

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
        local ctx = { buf = buf, mark = mark, response = response }
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
        local data
        if service == "anthropic" then
                data = {
                        system = "You are an AI code editor that returns patches.",
                        messages = {
                                {
                                        role = "user",
                                        content = user_prompt,
                                },
                        },
                        model = service_info.model,
                        max_tokens = 1024,
                }
        else
                data = {
                        messages = {
                                {
                                        role = "system",
                                        content = "You are an AI code editor that returns patches.",
                                },
                                {
                                        role = "user",
                                        content = user_prompt,
                                },
                        },
                        model = service_info.model,
                        temperature = 0,
                }
        end

        local args = {
                "-s",
                "-X",
                "POST",
                "-H",
                "Content-Type: application/json",
                "-d",
                vim.json.encode(data),
        }

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
                response = parsed.content and parsed.content[1] and parsed.content[1].text or ""
        else
                response =
                        parsed.choices
                        and parsed.choices[1]
                        and parsed.choices[1].message
                        and parsed.choices[1].message.content
                        or ""
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
