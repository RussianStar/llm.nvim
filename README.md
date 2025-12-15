# llm.nvim

A neovim plugin for no frills LLM-assisted programming.


https://github.com/melbaldove/llm.nvim/assets18225174/9bdc2fa1-ade4-48f2-87ce-3019fc323262


### Installation

Before using the plugin, set any of `GROQ_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` env vars with your api keys.

lazy.nvim
```lua
{
    "melbaldove/llm.nvim",
    dependencies = { "nvim-neotest/nvim-nio" }
}
```

### Usage

**`setup()`**

Configure the plugin. This can be omitted to use the default configuration.

```lua
require('llm').setup({
    -- How long to wait for the request to start returning data.
    timeout_ms = 10000,
    services = {
        -- Supported services configured by default
        -- groq = {
        --     url = "https://api.groq.com/openai/v1/chat/completions",
        --     model = "llama3-70b-8192",
        --     api_key_name = "GROQ_API_KEY",
        -- },
        -- openai = {
        --     url = "https://api.openai.com/v1/chat/completions",
        --     model = "gpt-4o",
        --     api_key_name = "OPENAI_API_KEY",
        -- },
        -- anthropic = {
        --     url = "https://api.anthropic.com/v1/messages",
        --     model = "claude-3-5-sonnet-20240620",
        --     api_key_name = "ANTHROPIC_API_KEY",
        -- },

        -- Extra OpenAI-compatible services to add (optional)
        other_provider = {
            url = "https://example.com/other-provider/v1/chat/completions",
            model = "llama3",
            api_key_name = "OTHER_PROVIDER_API_KEY",
        }
    }
})
```

**Example OpenRouter Configuration**

```lua
require('llm').setup({
    timeout_ms = 14000,
    services = {
        openrouter = {
            url = "https://openrouter.ai/api/v1/chat/completions",
            model = "anthropic/claude-3.5-sonnet",
            api_key_name = "OPENROUTER_API_KEY",
        },
    },
})

-- Quickly open or create an llm.md buffer for longer prompts
vim.keymap.set("n", "<leader>ma", function() require("llm").create_llm_md() end)

-- Pick an OpenRouter model via Telescope fuzzy search
vim.keymap.set("n", "<leader>ms", function() require("llm").pick_openrouter_model() end)

-- Stop an in-flight request if the model is still streaming
vim.keymap.set("n", "<leader>mt", function() require("llm").cancel() end)

vim.keymap.set("n", "<leader>,", function() require("llm").prompt({ replace = false, service = "openrouter" }) end)
vim.keymap.set("v", "<leader>,", function() require("llm").prompt({ replace = false, service = "openrouter" }) end)
vim.keymap.set("v", "<leader>.", function() require("llm").prompt({ replace = true, service = "openrouter" }) end)
```

**`prompt()`**

Triggers the LLM assistant. You can pass an optional `replace` flag to replace the current selection with the LLM's response. The prompt is either the visually selected text or the file content up to the cursor if no selection is made.

**`cancel()`**

Stops the current request if one is running.

**`edit()`**

Send one-shot edit requests that return multi-file patches. Pass a list of file paths as
context and the model must reply with diff blocks for only those paths; responses that
reference other files are rejected. By default edits
are checked without writing—set `apply = true` to persist. You can override the generated
context by providing a custom `context` string. New files may be created when
`allow_new_files = true`.

```lua
require('llm').edit({
    service = 'openai',
    files = { 'lua/llm.lua', 'README.md' },
    prompt = 'update docs',
    apply = true,
    allow_new_files = true,
})
```

**`create_llm_md()`**

Creates a new `llm.md` file in the current working directory, where you can write questions or prompts for the LLM.

**`token_count()`**

Prints a token count for all files tracked in the current git repository. If the
[`tiktoken`](https://github.com/openai/tiktoken) Python package is installed,
it is used for an exact count; otherwise an estimate of one token per four
characters is used. You can also call this via `:LLMTokenCount`.

**`pick_openrouter_model()`**

Queries `https://openrouter.ai/api/v1/models` and opens a Telescope picker so you can set
the OpenRouter model for subsequent prompts. Requires `telescope.nvim` to be installed.

**Example Bindings**
```lua
vim.keymap.set("n", "<leader>m", function() require("llm").create_llm_md() end)

-- keybinds for prompting with groq
vim.keymap.set("n", "<leader>,", function() require("llm").prompt({ replace = false, service = "groq" }) end)
vim.keymap.set("v", "<leader>,", function() require("llm").prompt({ replace = false, service = "groq" }) end)
vim.keymap.set("v", "<leader>.", function() require("llm").prompt({ replace = true, service = "groq" }) end)

-- keybinds for prompting with openai
vim.keymap.set("n", "<leader>g,", function() require("llm").prompt({ replace = false, service = "openai" }) end)
vim.keymap.set("v", "<leader>g,", function() require("llm").prompt({ replace = false, service = "openai" }) end)
vim.keymap.set("v", "<leader>g.", function() require("llm").prompt({ replace = true, service = "openai" }) end)
```

**`diff.apply_response()`**

Utility for applying multi‑file diffs emitted by an LLM. Each diff block should be wrapped like:

````
```diff file=path/to/file.lua
@@
-old line
+new line
@@
```
````

Options:

- `retry` – number of times to retry if the dry run fails (default `0`).
- `dry_run` – only check if the patch applies cleanly without writing to disk.
- `allow_new_files` – permit diff blocks that create new files (default `false`).
- `files` – list of paths that may be modified; unexpected paths raise an error.

Example:

```lua
local diff = require('llm.diff')
local ok, err = diff.apply_response(response, { retry = 1 })
```

### Roadmap
- [ollama](https://github.com/ollama/ollama) support

### Credits

- Special thanks to [yacine](https://twitter.com/i/broadcasts/1kvJpvRPjNaKE) and his ask.md vscode plugin for inspiration!
