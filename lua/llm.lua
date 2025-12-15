local nio = require("nio")
local diff = require("llm.diff")
local store = require("llm.store")
local M = {}

local timeout_ms = 5000
local log_level = vim.log.levels.INFO
local sign_defined = false
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_interval = 100
local progress_sign = {
        text = ">>",
        texthl = "DiagnosticHint",
        numhl = "DiagnosticHint",
}

local function normalize_log_level(level)
        if type(level) == "number" then
                return level
        end
        if type(level) == "string" then
                local name = level:upper()
                return vim.log.levels[name] or log_level
        end
        return log_level
end

local function log(level, msg)
        level = normalize_log_level(level)
        if level < log_level then
                return
        end
        local prefix = "llm.nvim: "
        vim.schedule(function()
                if vim and vim.notify then
                        vim.notify(prefix .. msg, level)
                else
                        print(prefix .. msg)
                end
        end)
end

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

                -- Some providers send reasoning in a separate field
                if delta.reasoning and delta.reasoning ~= "" and not opts.trim_thinking then
                        return delta.reasoning
                end

                local content = delta.content
                if type(content) == "table" then
                        local chunks = {}
                        for _, part in ipairs(content) do
                                if part.type == "reasoning" then
                                        if not opts.trim_thinking and part.text then
                                                table.insert(chunks, part.text)
                                        end
                                elseif part.type == "text" and part.text then
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

                -- Some providers include reasoning outside of content
                local reasoning = (message and message.reasoning)

                if type(content) == "table" then
                        local parts = {}
                        for _, item in ipairs(content) do
                                if item.type == "reasoning" then
                                        if not opts.trim_thinking and item.text then
                                                table.insert(parts, item.text)
                                        end
                                elseif item.type == "text" and item.text then
                                        table.insert(parts, item.text)
                                end
                                ::continue::
                        end
                        if reasoning and not opts.trim_thinking then
                                table.insert(parts, tostring(reasoning))
                        end
                        return table.concat(parts, "")
                elseif type(content) == "string" then
                        if reasoning and not opts.trim_thinking then
                                return content .. tostring(reasoning)
                        end
                        if opts.trim_thinking then
                                return content:gsub("<think>[%s%S]-</think>", "")
                        end
                        return content
                end

                if reasoning and not opts.trim_thinking then
                        return tostring(reasoning)
                end
                return ""
        end,
}

-- Track streaming processes so they can be cancelled independently
local current_responses = {}

-- Namespace for extmarks used when streaming results
local ns = vim.api.nvim_create_namespace("llm")

local function ensure_progress_signs()
        if sign_defined then
                return
        end
        for i, ch in ipairs(spinner_frames) do
                pcall(vim.fn.sign_define, "llm_progress_" .. i, {
                        text = ch,
                        texthl = progress_sign.texthl,
                        numhl = progress_sign.numhl,
                })
        end
        sign_defined = true
end

local function update_progress_sign(ctx, frame)
        if not ctx.sign_id or ctx.stopped then
                return
        end
        ensure_progress_signs()
        local pos = vim.api.nvim_buf_get_extmark_by_id(ctx.buf, ns, ctx.mark, {})
        if not pos or #pos == 0 then
                return
        end
        local lnum = pos[1] + 1
        local name = "llm_progress_" .. frame
        pcall(vim.fn.sign_unplace, "llm", { buffer = ctx.buf, id = ctx.sign_id })
        pcall(vim.fn.sign_place, ctx.sign_id, "llm", name, ctx.buf, { lnum = lnum, priority = 15 })
end

local function place_progress_sign(ctx)
        ensure_progress_signs()
        local pos = vim.api.nvim_buf_get_extmark_by_id(ctx.buf, ns, ctx.mark, {})
        local lnum = pos and pos[1] and (pos[1] + 1) or (vim.api.nvim_win_get_cursor(0)[1])
        local ok, id = pcall(vim.fn.sign_place, 0, "llm", "llm_progress_1", ctx.buf, {
                lnum = lnum,
                priority = 15,
        })
        if not ok then
                log("debug", "failed to place progress sign: " .. tostring(id))
                return nil, nil
        end

        local frame = 1
        local timer = vim.loop.new_timer()
        if timer then
                timer:start(
                        spinner_interval,
                        spinner_interval,
                        vim.schedule_wrap(function()
                                if ctx.stopped then
                                        return
                                end
                                frame = frame % #spinner_frames + 1
                                update_progress_sign(ctx, frame)
                        end)
                )
        end

        update_progress_sign(ctx, frame)
        return id, timer
end

local function remove_progress_sign(bufnr, id)
        if not id then
                return
        end
        pcall(vim.fn.sign_unplace, "llm", { buffer = bufnr, id = id })
end

local function stop_ctx(ctx, reason)
        if ctx.stopped then
                return
        end
        ctx.stopped = true

        remove_progress_sign(ctx.buf, ctx.sign_id)

        if current_responses[ctx.response] then
                        current_responses[ctx.response] = nil
        end

        if ctx.response then
                if ctx.response.stdout and ctx.response.stdout.close then
                        ctx.response.stdout.close()
                end
                if ctx.response.kill then
                        pcall(ctx.response.kill, ctx.response)
                end
        end

        if ctx.spinner_timer then
                pcall(ctx.spinner_timer.stop, ctx.spinner_timer)
                pcall(ctx.spinner_timer.close, ctx.spinner_timer)
                ctx.spinner_timer = nil
        end

        if reason then
                log("info", reason)
        end
end

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
                stream_params = {},
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
        opts = opts or {}
        timeout_ms = opts.timeout_ms or timeout_ms
        if opts.log_level then
                log_level = normalize_log_level(opts.log_level)
        elseif opts.debug then
                log_level = vim.log.levels.DEBUG
        end
        if opts.progress_sign then
                progress_sign = vim.tbl_extend("force", progress_sign, opts.progress_sign)
                sign_defined = false -- force re-define with new icon
        end
        if opts.spinner_frames and vim.islist(opts.spinner_frames) and #opts.spinner_frames > 0 then
                spinner_frames = opts.spinner_frames
                sign_defined = false
        end
        if opts.spinner_interval then
                spinner_interval = opts.spinner_interval
        end
        if opts.services then
                for key, service in pairs(opts.services) do
                        if not service.adapter then
                                service.adapter = default_openai_adapter
                        end
                        service_lookup[key] = service
                end
        end

        local last = store.load_last()
        if last and last.service and service_lookup[last.service] then
                local svc = service_lookup[last.service]
                if last.model then
                        svc.model = last.model
                end
                if last.trim_thinking ~= nil then
                        svc.trim_thinking = last.trim_thinking
                end
                if last.stream_params then
                        svc.stream_params = last.stream_params
                end
                -- ignore stored headers to avoid sending optional OpenRouter headers by default
                if last.data_collection ~= nil then
                        svc.data_collection = last.data_collection
                end
                log(
                        "info",
                        string.format(
                                "restored last model '%s' for service '%s'",
                                tostring(last.model),
                                tostring(last.service)
                        )
                )
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
                                        store.save_last("openrouter", {
                                                model = selection.value,
                                                trim_thinking = service.trim_thinking,
                                                stream_params = service.stream_params,
                                        })
                                end

                                actions.select_default:replace(set_model)
                                return true
                        end,
                })
                :find()
end

local function pick_openrouter_thinking()
        local ok = pcall(require, "telescope")
        if not ok then
                print("llm.nvim: telescope.nvim is required for thinking mode selection")
                return
        end

        local service = get_service("openrouter")
        if not service then
                return
        end

        local entries = {
                { value = false, display = "Hide thinking tokens (default)", ordinal = "hide" },
                { value = true, display = "Show thinking tokens", ordinal = "show" },
        }

        local pickers = require("telescope.pickers")
        local finders = require("telescope.finders")
        local conf = require("telescope.config").values
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")

        pickers
                .new({}, {
                        prompt_title = "OpenRouter Thinking Mode",
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
                        attach_mappings = function(prompt_bufnr, _)
                                local function set_mode()
                                        local selection = action_state.get_selected_entry()
                                        actions.close(prompt_bufnr)
                                        if not selection then
                                                return
                                        end
                                        service.trim_thinking = selection.value
                                        store.save_last("openrouter", {
                                                model = service.model,
                                                trim_thinking = service.trim_thinking,
                                                stream_params = service.stream_params,
                                        })
                                        local label = selection.value and "show" or "hide"
                                        print("llm.nvim: OpenRouter thinking tokens set to " .. label)
                                end

                                actions.select_default:replace(set_mode)
                                return true
                        end,
                })
                :find()
end

local function pick_openrouter_thinking_effort()
        local ok = pcall(require, "telescope")
        if not ok then
                print("llm.nvim: telescope.nvim is required for thinking effort selection")
                return
        end

        local service = get_service("openrouter")
        if not service then
                return
        end

        local entries = {
                { value = "low", display = "Low reasoning effort (faster/cheaper)" },
                { value = "medium", display = "Medium reasoning effort (default)" },
                { value = "high", display = "High reasoning effort (more tokens/slower)" },
                { value = vim.NIL, display = "Unset (model default)" },
        }

        local pickers = require("telescope.pickers")
        local finders = require("telescope.finders")
        local conf = require("telescope.config").values
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")

        pickers
                .new({}, {
                        prompt_title = "OpenRouter Reasoning / Thinking Effort",
                        finder = finders.new_table({
                                results = entries,
                                entry_maker = function(entry)
                                        return {
                                                value = entry.value,
                                                display = entry.display,
                                                ordinal = entry.display,
                                        }
                                end,
                        }),
                        sorter = conf.generic_sorter({}),
                        attach_mappings = function(prompt_bufnr, _)
                                local function set_mode()
                                        local selection = action_state.get_selected_entry()
                                        actions.close(prompt_bufnr)
                                        if not selection then
                                                return
                                        end
                                        service.stream_params = service.stream_params or {}
                                        if selection.value == vim.NIL then
                                                service.stream_params.reasoning_effort = nil
                                        else
                                                service.stream_params.reasoning_effort = selection.value
                                        end
                                        store.save_last("openrouter", {
                                                model = service.model,
                                                trim_thinking = service.trim_thinking,
                                                stream_params = service.stream_params,
                                        })
                                        print(
                                                "llm.nvim: OpenRouter reasoning_effort set to "
                                                        .. tostring(selection.value or "default")
                                        )
                                end

                                actions.select_default:replace(set_mode)
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
                ctx.writing = true
                vim.api.nvim_buf_set_text(buf, row, col, row, col, lines)
                ctx.writing = false
        end)

        local last_line = lines[#lines]
        local new_row = row + #lines - 1
        local new_col = #lines == 1 and col + #last_line or #last_line
        vim.api.nvim_buf_set_extmark(buf, ns, new_row, new_col, { id = mark })
end

local function split_lines(buffer)
        local lines = {}
        local idx = 1
        while true do
                local s, e = buffer:find("\r?\n", idx)
                if not s then
                        break
                end
                table.insert(lines, buffer:sub(idx, s - 1))
                idx = e + 1
        end
        return lines, buffer:sub(idx)
end

local function handle_non_stream_body(body, ctx, service)
        if not body or not body:match("%S") then
            return false
        end

        log("info", "received non-stream response, attempting to parse")
        local ok, data = pcall(vim.json.decode, body)
        if not ok then
                log("warn", "non-stream response is not valid json")
                return false
        end

        if data.error then
                local msg = data.error.message or vim.inspect(data.error)
                log("error", "provider returned error: " .. msg)
                print("llm.nvim error: " .. msg)

                -- surface full response for troubleshooting
                log("error", "full error response (parsed): " .. vim.inspect(data))
                log("error", "full error response (raw): " .. body)

                if msg:lower():find("data policy") or msg:lower():find("privacy") then
                        log(
                                "info",
                                "OpenRouter data policy mismatch. Free models often require allowing publication/training at https://openrouter.ai/settings/privacy; adjust there or pick a paid/privacy-compatible model."
                        )
                end
                return false
        end

        local content
        if service == "anthropic" then
                content = ctx.adapter.extract_message_content(data.content, { trim_thinking = ctx.trim_thinking })
        else
                local message = data.choices and data.choices[1] and data.choices[1].message
                content = ctx.adapter.extract_message_content(message, { trim_thinking = ctx.trim_thinking })
        end

        if content and content ~= "" then
                write_at_mark(ctx, sanitize_content(content))
                log("info", "wrote non-stream response to buffer (" .. #content .. " chars)")
                return true
        end

        log("warn", "non-stream response had no content field")
        return false
end

local function process_data_lines(lines, service, ctx, process_data)
        for _, line in ipairs(lines) do
                local data_start = line:find("data: ")
                if data_start then
                        local json_str = line:sub(data_start + 6)
                        local stop = false
                        if line == "data: [DONE]" then
                                log("debug", "received [DONE] signal")
                                return true
                        end
                        local ok, data = pcall(vim.json.decode, json_str)
                        if not ok then
                                log("warn", "failed to parse stream chunk")
                                return false
                        end
                        if data.error then
                                local msg = data.error.message or vim.inspect(data.error)
                                print("llm.nvim error: " .. msg)
                                log("error", "provider error: " .. msg)
                                log("error", "full error chunk: " .. vim.inspect(data))
                                return true
                        end
                        if service == "anthropic" then
                                stop = data.type == "message_stop"
                        end
                        if stop then
                                check_limits(data, service)
                                return true
                        else
                                log("debug", "processing streamed chunk")
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
        local has_output = false
        local bytes_read = 0
        local seen_lines = 0
        local err_output = {}
        local timed_out = false
        local timeout_logged = false
        local start_time = vim.uv.hrtime()
        current_responses[response] = ctx

        local function finalize(reason)
                if reason then
                        log(
                                "debug",
                                string.format(
                                        "finalizing stream: %s (bytes=%d, buffered=%d, lines=%d, tokens=%s)",
                                        reason,
                                        bytes_read,
                                        #buffer,
                                        seen_lines,
                                        tostring(has_tokens)
                                )
                        )
                end
                if timed_out and not has_tokens then
                        log(
                                "info",
                                "timeout without tokens — check network reachability, API key validity, model name/availability, org/plan limits, or provider-side rate limiting"
                        )
                end
                stop_ctx(ctx)
        end

        local function maybe_log_timeout()
                if timeout_logged or has_output or ctx.stopped or ctx.user_cancelled then
                        return
                end
                local elapsed_ms = (vim.uv.hrtime() - start_time) / 1e6
                if elapsed_ms >= timeout_ms and not has_tokens then
                        timed_out = true
                        timeout_logged = true
                        log("error", "request timed out after " .. timeout_ms .. "ms without receiving any output")
                        print("llm.nvim has timed out!")
                end
        end

        local done = false
        while not done do
                if ctx.stopped or ctx.user_cancelled then
                        finalize("cancelled")
                        return
                end
                maybe_log_timeout()
                local chunk = response.stdout.read(1)
                local err_chunk = response.stderr.read(1)
                if err_chunk and #err_chunk > 0 then
                        local msg = vim.trim(err_chunk)
                        if msg ~= "" then
                                log("warn", "curl stderr: " .. msg)
                                table.insert(err_output, msg)
                                has_output = true
                        end
                end
                if chunk == nil then
                        break
                end
                if chunk ~= "" then
                        buffer = buffer .. chunk
                        bytes_read = bytes_read + #chunk
                        has_output = true

                        local lines
                        lines, buffer = split_lines(buffer)
                        if #lines > 0 then
                                seen_lines = seen_lines + #lines
                        end

                        done = process_data_lines(lines, service, ctx, function(data)
                                local content
                                if ctx.adapter and ctx.adapter.extract_stream_content then
                                        content = ctx.adapter.extract_stream_content(
                                                data,
                                                { trim_thinking = ctx.trim_thinking }
                                        )
                                end
                                if content and content ~= vim.NIL and content ~= "" then
                                        content = sanitize_content(content)
                                        has_tokens = true
                                        if not ctx.stopped and not ctx.user_cancelled then
                                                write_at_mark(ctx, content)
                                                update_progress_sign(ctx, 1)
                                        end
                                end
                        end)
                else
                        -- brief yield to avoid busy-wait but keep latency low
                        nio.sleep(10)
                end
        end

        if not has_tokens and buffer and buffer:match("%S") then
                if handle_non_stream_body(buffer, ctx, service) then
                        has_tokens = true
                        has_output = true
                end
        elseif not has_tokens and #buffer == 0 then
                local err_summary = table.concat(err_output, " | ")
                log(
                        "error",
                        string.format(
                                "no response body received (bytes=%d, stderr=%s) - possible causes: network block, invalid API key, model unavailable, or provider dropped stream",
                                bytes_read,
                                err_summary ~= "" and err_summary or "none"
                        )
                )
        end

        finalize(timed_out and "timeout" or "stream complete")
end

local function collect_imports(bufnr, max_lines)
        max_lines = max_lines or 200
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, max_lines, false)
        local imports = {}
        for _, l in ipairs(lines) do
                if l:match("^%s*#include") or l:match("^%s*import ") or l:match("^%s*from .+ import") or l:match("^%s*use ") or l:match("^%s*using ") or l:match("^%s*require") then
                        table.insert(imports, l)
                end
        end
        return imports
end

local default_base_prompt = [[I am an experienced software developer who doesn't need install or other basic information. If I do, I will ask. I value creativity and boldness, living a vital and expressive life.]]

local function build_system_prompt(bufnr, base_prompt)
        local ft = vim.bo[bufnr].filetype or "plain"
        local imports = collect_imports(bufnr)
        local imports_block = #imports > 0 and table.concat(imports, "\n") or "None detected"
        return table.concat({
                base_prompt,
                "",
                "-- Editor context --------------------------------------------------",
                "You are inside Neovim. Respond with text to insert into the buffer only (no Markdown fences, no headings).",
                "If explanation is needed, write it as comments in the target language at the top; otherwise output code only.",
                "Prefer adding comments inline or directly above new code; keep them minimal and relevant.",
                "Do not include installation/setup steps unless explicitly requested.",
                "Never echo the user's prompt; do not add surrounding prose.",
                "Adopt the file's language style and existing imports.",
                "",
                string.format("Filetype: %s", ft),
                "Imports:",
                imports_block,
                "-------------------------------------------------------------------",
        }, "\n")
end

function M.prompt(opts)
	local replace = opts.replace
	local service = opts.service
	local prompt = ""
	local visual_lines = M.get_visual_selection()
        local buf = vim.api.nvim_get_current_buf()
        local base_prompt = opts.base_prompt or default_base_prompt
	local system_prompt = build_system_prompt(buf, base_prompt)
	if visual_lines then
		prompt = table.concat(visual_lines, "\n")
		if replace then
			system_prompt =
				build_system_prompt(buf, base_prompt)
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

        local has_api_key = api_key_name and get_api_key(api_key_name) ~= nil
        log(
                "info",
                string.format(
                        "sending request to %s with model %s (timeout=%dms, trim_thinking=%s, api_key=%s)",
                        service,
                        model,
                        timeout_ms,
                        tostring(trim_thinking),
                        has_api_key and "yes" or "no"
                )
        )
        log("debug", "system prompt length: " .. #system_prompt .. ", user prompt length: " .. #prompt)

        adapter = adapter or default_openai_adapter
        trim_thinking = trim_thinking or false

        local api_key = api_key_name and get_api_key(api_key_name)

        -- Persist last-used configuration for convenience
        store.save_last(service, {
                model = model,
                trim_thinking = trim_thinking,
                stream_params = stream_params,
        })

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

        -- Log request metadata without leaking secrets
        local safe_headers = {}
        for _, v in ipairs(args) do
                if type(v) == "string" and v:match("^Authorization:") then
                        table.insert(safe_headers, "Authorization: ***redacted***")
                elseif type(v) == "string" and v:match("^x%-api%-key:") then
                        table.insert(safe_headers, "x-api-key: ***redacted***")
                elseif type(v) == "string" and v:match("^anthropic%-version:") then
                        table.insert(safe_headers, v)
                elseif type(v) == "string" and v:match("^Content%-Type:") then
                        table.insert(safe_headers, v)
                end
        end
        log(
                "debug",
                string.format(
                        "curl args: method=POST url=%s headers=%s content_length=%d",
                        url,
                        vim.inspect(safe_headers),
                        #vim.json.encode(data)
                )
        )

        -- capture buffer and position for streaming
        local buf = vim.api.nvim_get_current_buf()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        -- insert a new line where output will be written
        vim.api.nvim_buf_set_lines(buf, row, row, true, { "" })
        local mark = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {})
        local ctx = {
                buf = buf,
                mark = mark,
        }
        local sign_id, spinner_timer = place_progress_sign(ctx)

        local response = nio.process.run({
                cmd = "curl",
                args = args,
        })
        ctx.sign_id = sign_id
        ctx.spinner_timer = spinner_timer
        ctx.response = response
        ctx.adapter = adapter
        ctx.trim_thinking = trim_thinking
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
                remove_progress_sign(ctx.buf, ctx.sign_id)
                ctx.user_cancelled = true
                ctx.response.stdout.close()
                if ctx.response.kill then
                        ctx.response:kill()
                end
                stop_ctx(ctx, "request cancelled")
                cancelled = true
        end
        current_responses = {}
        if cancelled then
                print("llm.nvim request cancelled")
        else
                print("llm.nvim: no active request")
        end
end

function M.cancel_at_cursor()
        local buf = vim.api.nvim_get_current_buf()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        for _, ctx in pairs(current_responses) do
                if ctx.buf == buf then
                        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, ctx.mark, {})
                        if pos and pos[1] + 1 == row then
                                nio.run(function()
                                        stop_ctx(ctx, "request cancelled at cursor line")
                                end)
                                print("llm.nvim: cancelled request at line " .. row)
                                return
                        end
                end
        end
        print("llm.nvim: no request at cursor line")
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
M.pick_openrouter_thinking = pick_openrouter_thinking
M.pick_openrouter_thinking_effort = pick_openrouter_thinking_effort

function M.hide_thinking_tokens()
        local service = get_service("openrouter")
        if not service then
                return
        end
        service.trim_thinking = true
        store.save_last("openrouter", {
                model = service.model,
                trim_thinking = service.trim_thinking,
                stream_params = service.stream_params,
        })
        print("llm.nvim: OpenRouter thinking tokens will be trimmed")
end

return M
