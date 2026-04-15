local M = {}

local function get_file()
	local dir = vim.fn.stdpath("data") .. "/edit-tools"
	vim.fn.mkdir(dir, "p")
	return dir .. "/knowledge.jsonl"
end

local function detect_type(lines)
	local text = table.concat(lines, "\n")

	if text:match("%d+%.%d+%.%d+%.%d+/%d+") then
		return "ip"
	end

	if text:match("SELECT%s") or text:match("INSERT%s") or text:match("UPDATE%s") then
		return "sql"
	end

	if text:match("func%s") or text:match("function%s") or text:match("class%s") then
		return "code"
	end

	return "text"
end

local function detect_tags(lines)
	local text = table.concat(lines, "\n")
	local tags = {}

	if text:match("vim%.") or text:match("nvim") then
		table.insert(tags, "neovim")
	end

	if text:match("SELECT%s") then
		table.insert(tags, "sql")
	end

	if text:match("function%s") then
		table.insert(tags, "lua")
	end

	if text:match("%d+%.%d+%.%d+%.%d+") then
		table.insert(tags, "network")
	end

	return tags
end

function M.save_visual_selection()
	local s = vim.fn.getpos("'<")
	local e = vim.fn.getpos("'>")

	local lines = vim.api.nvim_buf_get_lines(0, s[2] - 1, e[2], false)

	if #lines == 0 then
		vim.notify("空选区", vim.log.levels.WARN)
		return
	end

	local file = io.open(get_file(), "a")
	if not file then
		vim.notify("无法写入 history", vim.log.levels.ERROR)
		return
	end

	local entry = {
		time = os.date("%Y-%m-%d %H:%M:%S"),

		-- 结构分类（保留）
		type = detect_type(lines),

		-- 语义标签（新增）
		tags = detect_tags(lines),

		-- 标题
		title = lines[1] and lines[1]:sub(1, 80) or "untitled",

		-- 内容
		content = table.concat(lines, "\n"),
	}

	file:write(vim.json.encode(entry) .. "\n")
	file:close()

	vim.notify("已保存: " .. entry.type, vim.log.levels.INFO)
end

function M.setup()
	vim.keymap.set("v", "<leader>is", M.save_visual_selection, {
		desc = "Save snippet (auto typed)",
		silent = true,
	})
end

return M
