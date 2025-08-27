local M = {}

-- Extract diff blocks formatted as:
-- ```diff file=path/to/file
-- @@
-- -old
-- +new
-- @@
-- ```
-- Returns a list of {path=..., diff=...}
local function parse_blocks(response)
        local blocks = {}
        for path, diff in response:gmatch("```diff file=([^\n]+)\n([\000-\255]-)```") do
                table.insert(blocks, { path = path, diff = diff })
        end
        local stripped = response:gsub("```diff file=[^\n]+\n[\000-\255]-```", "")
        if stripped:match("%S") then
                return nil, "invalid diff format"
        end
        return blocks
end

-- Build a combined patch from parsed blocks
local function build_patch(blocks)
        local parts = {}
        for _, b in ipairs(blocks) do
                local old = b.new and "/dev/null" or b.path
                table.insert(parts, string.format("--- %s\n+++ %s\n%s", old, b.path, b.diff))
        end
        return table.concat(parts, "\n")
end

local function git_apply(patch, check)
        local args = { "git", "apply" }
        if check then
                table.insert(args, "--check")
        end
        local result = vim.system(args, { text = true, stdin = patch }):wait()
        return result.code == 0, result.stdout .. result.stderr
end

-- Apply an LLM diff response to the working directory.
-- opts.retry: number of times to retry on failure (default 0)
-- opts.dry_run: if true, only run the check phase
function M.apply_response(response, opts)
        opts = opts or {}
        local retry = opts.retry or 0
        local dry_run = opts.dry_run or false
        local allow_new = opts.allow_new_files or false

        local blocks, err = parse_blocks(response)
        if not blocks then
                return false, err
        end
        if #blocks == 0 then
                return false, "no diff blocks found"
        end

        local allowed
        if opts.files then
                allowed = {}
                for _, f in ipairs(opts.files) do
                        allowed[f] = true
                end
        end

        for _, b in ipairs(blocks) do
                if b.path:sub(1, 1) == "/" or b.path:find("%.%.") then
                        return false, "invalid path: " .. b.path
                end
                if not b.diff:match("\n@@") and not b.diff:match("^@@") then
                        return false, "invalid diff for file: " .. b.path
                end
                local stat = vim.loop.fs_stat(b.path)
                b.new = not stat
                if allowed and not allowed[b.path] and not (b.new and allow_new) then
                        return false, "file not in context: " .. b.path
                end
                if b.new and not allow_new then
                        return false, "new file not allowed: " .. b.path
                end
        end

        local patch = build_patch(blocks)

        local attempt = 0
        while true do
                attempt = attempt + 1
                local ok, msg = git_apply(patch, true)
                if ok then
                        if not dry_run then
                                git_apply(patch, false)
                        end
                        return true
                elseif attempt > retry then
                        return false, msg
                end
        end
end

return M

