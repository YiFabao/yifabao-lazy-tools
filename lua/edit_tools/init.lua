local M = {}

function M.setup()
	require("edit_tools.ip").setup()
	require("edit_tools.history").setup()
	require("edit_tools.telescope").setup()
end

return M
