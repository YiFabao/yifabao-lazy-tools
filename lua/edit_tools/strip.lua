--- 文本清理工具：去标点、行格式化
local M = {}

-- 需要去除的标点符号字符集
-- 包含：中英文引号、逗号、句号、括号、方括号、花括号、冒号、分号等
local PUNCTUATION_PATTERN = [=[[""'',，。.、;；:：!！?？()（）\[\]{}【】《》<>`~@#%^&*_+=|\\/·—…%-]]=]

--- 获取视觉选区的行范围（0-indexed start, exclusive end）
--- @return number, number
local function get_visual_range()
	vim.fn.setpos("'<", vim.fn.getpos("v"))
	vim.fn.setpos("'>", vim.fn.getpos("."))

	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")

	return start_pos[2] - 1, end_pos[2]
end

--- 去除选区中所有标点符号
function M.strip_punctuation()
	local bufnr = 0
	local start_line, end_line = get_visual_range()

	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)

	local results = {}
	for _, line in ipairs(lines) do
		local cleaned = line:gsub(PUNCTUATION_PATTERN, "")
		table.insert(results, cleaned)
	end

	vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, results)

	vim.notify("已去除选区中的标点符号", vim.log.levels.INFO)
end

--- 每行去除首尾空格，加双引号，加逗号（最后一行不加逗号）
--- 示例：
---   hello world   →  "hello world",
---   foo bar       →  "foo bar",
---   baz           →  "baz"
function M.format_lines()
	local bufnr = 0
	local start_line, end_line = get_visual_range()

	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)

	-- 先过滤掉空行，避免对空白行产生无意义的引号
	local filtered = {}
	for _, line in ipairs(lines) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			table.insert(filtered, trimmed)
		end
	end

	if #filtered == 0 then
		vim.notify("选区中没有非空行", vim.log.levels.WARN)
		return
	end

	local results = {}
	for i, text in ipairs(filtered) do
		if i < #filtered then
			table.insert(results, string.format('"%s",', text))
		else
			table.insert(results, string.format('"%s"', text))
		end
	end

	vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, results)

	vim.notify(string.format("已格式化 %d 行", #results), vim.log.levels.INFO)
end

function M.setup(opts)
	opts = opts or {}
	local strip_keymap = opts.strip_keymap or "<leader>iq"
	local format_keymap = opts.format_keymap or "<leader>iL"

	vim.keymap.set("v", strip_keymap, M.strip_punctuation, {
		desc = "Strip punctuation from selection",
		silent = true,
	})

	vim.keymap.set("v", format_keymap, M.format_lines, {
		desc = "Format lines: trim, quote, comma (last line no comma)",
		silent = true,
	})
end

return M
