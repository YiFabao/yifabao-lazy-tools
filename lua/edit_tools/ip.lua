local M = {}

function M.format_selected_ips()
	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")
	local lines = vim.fn.getline(start_pos[2], end_pos[2])

	local results = {}
	local seen = {}

	for _, line in ipairs(lines) do
		local ip = vim.trim(line):match("(%d+%.%d+%.%d+%.%d+/%d+)")
		if ip and not seen[ip] then
			seen[ip] = true
			table.insert(results, string.format('        "%s",', ip))
		end
	end

	vim.fn.setline(start_pos[2], results)
end

function M.setup()
	vim.keymap.set("v", "<leader>ip", M.format_selected_ips, {
		desc = "Format selected CIDR IPs",
	})
end

return M
