--- IP 地址提取和格式化工具
--- 支持 CIDR (x.x.x.x/y) 和单IP (x.x.x.x) 提取
local M = {}

--- 验证 CIDR 前缀是否有效 (0-32)
--- @param prefix number
--- @return boolean
local function is_valid_cidr_prefix(prefix)
	return prefix >= 0 and prefix <= 32
end

--- 验证 IP 地址是否合法 (每段 0-255)
--- @param ip string
--- @return boolean
local function is_valid_ip(ip)
	local octets = {}
	for octet in ip:gmatch("%d+") do
		table.insert(octets, tonumber(octet))
	end
	if #octets ~= 4 then
		return false
	end
	for _, o in ipairs(octets) do
		if o < 0 or o > 255 then
			return false
		end
	end
	return true
end

--- IP 地址转换为可排序的数字 (用于排序)
--- @param ip string
--- @return number
local function ip_to_number(ip)
	local base = ip:match("^(%d+%.%d+%.%d+%.%d+)")
	if not base then
		return 0
	end
	local n1, n2, n3, n4 = base:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
	return (tonumber(n1) or 0) * 16777216 + 
	       (tonumber(n2) or 0) * 65536 + 
	       (tonumber(n3) or 0) * 256 + 
	       (tonumber(n4) or 0)
end

--- 安全地执行 vim 操作并处理错误
--- @param fn function
--- @param err_msg string
local function safe_vim_exec(fn, err_msg)
	local ok, err = pcall(fn)
	if not ok then
		vim.notify(string.format("%s: %s", err_msg, tostring(err)), vim.log.levels.ERROR)
	end
end

--- 提取并格式化选区中的 IP 地址
--- @param opts table|nil 可选配置 { format = "cidr"|"ip"|"both", sort = boolean }
function M.format_selected_ips(opts)
	opts = opts or {}
	local format_mode = opts.format or "cidr"  -- cidr, ip, both
	local should_sort = opts.sort ~= false  -- 默认开启排序

	local bufnr = 0

	-- 强制更新视觉选区标记（确保 '< 和 '> 是当前选区）
	vim.fn.setpos("'<", vim.fn.getpos("v"))
	vim.fn.setpos("'>", vim.fn.getpos("."))

	-- 使用 getpos 获取选区起止位置（兼容性更好）
	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")

	local start_line = start_pos[2] - 1 -- 0-indexed
	local end_line = end_pos[2] -- 非 inclusive

	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)

	local cidr_results = {}
	local ip_results = {}
	local seen_cidr = {}
	local seen_ip = {}

	for _, line in ipairs(lines) do
		local trimmed = vim.trim(line)
		
		-- 提取 CIDR IP (x.x.x.x/y)
		if format_mode == "cidr" or format_mode == "both" then
			local cidr_ip, cidr_prefix = trimmed:match("(%d+%.%d+%.%d+%.%d+)/(%d+)")
			if cidr_ip and is_valid_ip(cidr_ip) then
				local prefix_num = tonumber(cidr_prefix)
				if prefix_num and is_valid_cidr_prefix(prefix_num) and not seen_cidr[cidr_ip] then
					seen_cidr[cidr_ip] = true
					table.insert(cidr_results, string.format('        "%s/%s",', cidr_ip, cidr_prefix))
				end
			end
		end

		-- 提取单IP (x.x.x.x，但不匹配CIDR中的IP)
		if format_mode == "ip" or format_mode == "both" then
			-- 先检查是否是 CIDR，如果是则跳过单IP提取
			if not trimmed:match("%d+%.%d+%.%d+%.%d+/%d+") then
				local single_ip = trimmed:match("(%d+%.%d+%.%d+%.%d+)")
				if single_ip and is_valid_ip(single_ip) and not seen_ip[single_ip] then
					seen_ip[single_ip] = true
					table.insert(ip_results, string.format('        "%s",', single_ip))
				end
			end
		end
	end

	-- 合并结果
	local results = {}
	vim.list_extend(results, cidr_results)
	vim.list_extend(results, ip_results)

	if #results == 0 then
		vim.notify("未找到 IP 地址 (CIDR 或 IPv4)", vim.log.levels.WARN)
		return
	end

	-- 排序 (按 IP 地址数值大小)
	if should_sort then
		table.sort(results, function(a, b)
			local ip_a = a:match('"(%d+%.%d+%.%d+%.%d+)')
			local ip_b = b:match('"(%d+%.%d+%.%d+%.%d+)')
			if ip_a and ip_b then
				return ip_to_number(ip_a) < ip_to_number(ip_b)
			end
			return a < b
		end)
	end

	-- 显示预览信息
	local preview_msg = string.format("找到 %d 个 IP (%d CIDR, %d 单IP)", 
		#results, #cidr_results, #ip_results)
	vim.notify(preview_msg .. " - 正在替换...", vim.log.levels.INFO)

	-- 创建撤销点
	vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, results)

	vim.notify(string.format("已替换 %d 个 IP 地址", #results), vim.log.levels.INFO)
end

--- 快速提取 CIDR IP (向后兼容)
function M.format_selected_cidrs()
	M.format_selected_ips({ format = "cidr", sort = true })
end

function M.setup(opts)
	opts = opts or {}
	local keymap = opts.keymap or "<leader>ip"

	vim.keymap.set("v", keymap, M.format_selected_ips, {
		desc = "Extract and replace selected IPs (CIDR + IPv4)",
		silent = true,
	})

	-- 向后兼容的旧键映射
	if opts.enable_legacy_keymap ~= false then
		vim.keymap.set("v", "<leader>ic", M.format_selected_cidrs, {
			desc = "Extract CIDR IPs only",
			silent = true,
		})
	end
end

return M
