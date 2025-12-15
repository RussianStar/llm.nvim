local M = {}

local function config_path()
        local data = vim.fn.stdpath("data")
        return data .. "/llm/config.json"
end

local function load_file()
        local path = config_path()
        local fd = io.open(path, "r")
        if not fd then
                return {}
        end
        local ok, data = pcall(vim.json.decode, fd:read("*a") or "")
        fd:close()
        if not ok or type(data) ~= "table" then
                return {}
        end
        return data
end

local function save_file(tbl)
        local path = config_path()
        local dir = vim.fn.fnamemodify(path, ":h")
        vim.fn.mkdir(dir, "p")
        local fd, err = io.open(path, "w")
        if not fd then
                return false, err
        end
        fd:write(vim.json.encode(tbl))
        fd:close()
        return true
end

function M.load_last()
        local data = load_file()
        return data.last
end

function M.save_last(service_name, cfg)
        local data = load_file()
        data.last = {
                service = service_name,
                model = cfg.model,
                category = cfg.category,
                trim_thinking = cfg.trim_thinking,
                stream_params = cfg.stream_params,
                data_collection = cfg.data_collection,
        }
        return save_file(data)
end

return M
