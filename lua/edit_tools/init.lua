--- edit_tools 配置入口
--- 使用示例:
---   require("edit_tools").setup({
---     ip = {
---       keymap = "<leader>ip",
---       enable_legacy_keymap = true,
---     },
---     knowledge = {
---       keymaps = {
---         knowledge_search = "<leader>ik",
---         statistics = "<leader>ist",
---       },
---     },
---   })

local M = {}

function M.setup(opts)
	opts = opts or {}

	-- 初始化 IP 工具
	require("edit_tools.ip").setup(opts.ip or {})

	-- 初始化知识库
	require("edit_tools.knowledge").setup(opts.knowledge or {})
end

return M
