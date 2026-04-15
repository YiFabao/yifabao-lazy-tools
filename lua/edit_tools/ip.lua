local M = {}

function M.format_selected_ips()
	local bufnr = 0

	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")

	local start_line = start_pos[2] - 1
	local end_line = end_pos[2]

	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)

	local results = {}
	local seen = {}

	for _, line in ipairs(lines) do
		local ip = vim.trim(line):match("(%d+%.%d+%.%d+%.%d+/%d+)")
		if ip and not seen[ip] then
			seen[ip] = true
			table.insert(results, string.format('        "%s",', ip))
		end
	end

	if #results == 0 then
		vim.notify("未找到 CIDR IP", vim.log.levels.WARN)
		return
	end

	-- 完整替换整个选区
	vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, results)

	vim.notify(string.format("已替换 %d 个 IP 段", #results), vim.log.levels.INFO)
end

function M.setup()
	vim.keymap.set("v", "<leader>ip", M.format_selected_ips, {
		desc = "Extract and replace selected CIDR IPs",
		silent = true,
	})
end

return M
