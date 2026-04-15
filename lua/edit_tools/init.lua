local M = {}

function M.setup()
	require("edit_tools.ip").setup()
	require("edit_tools.text").setup()
	require("edit_tools.json").setup()
end

return M
