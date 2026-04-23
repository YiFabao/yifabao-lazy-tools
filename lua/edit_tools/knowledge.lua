local M = {}
local sqlite = require("sqlite")
local db = nil

-- =========================
-- db
-- =========================
local function db_path()
	return vim.fn.stdpath("data") .. "/edit-tools/knowledge.db"
end

local function ensure_dir()
	local dir = vim.fn.fnamemodify(db_path(), ":h")
	vim.fn.mkdir(dir, "p")
end

local function init_db()
	ensure_dir()

	if db and db:isopen() then
		return
	end

	db = sqlite({ uri = db_path() })
	db:open()

	db:eval([[
    CREATE TABLE IF NOT EXISTS knowledge (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      time TEXT NOT NULL,
      type TEXT NOT NULL,
      tags TEXT DEFAULT '',
      title TEXT DEFAULT '',
      content TEXT NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
  ]])
end

local function ensure_db()
	if not db then
		init_db()
	end
end

-- =========================
-- helpers
-- =========================
local function split_tags(tag_str)
	local tags = {}
	if tag_str and tag_str ~= "" then
		for tag in tag_str:gmatch("[^,]+") do
			table.insert(tags, vim.trim(tag))
		end
	end
	return tags
end

local function detect_type(text)
	if text:match("function%s") then
		return "code"
	end
	return "text"
end

local function detect_tags(text)
	local tags = {}
	if text:match("function%s") then
		table.insert(tags, "lua")
	end
	return tags
end

-- =========================
-- ✅ 修复核心：save_content 支持 id + 返回 id
-- =========================
local function save_content(content, opts)
	ensure_db()
	if not content or content == "" then
		vim.notify("没有内容可以保存", vim.log.levels.WARN)
		return
	end

	opts = opts or {}
	local lines = vim.split(content, "\n")
	local text = table.concat(lines, "\n")

	local title = opts.title
	local tags = opts.tags
	local id = opts.id

	if not title then
		title = lines[1] and lines[1]:sub(1, 80) or "Pasted Content"
	end

	if not tags then
		tags = detect_tags(text)
	end

	if id then
		-- ✅ UPDATE
		db:eval(
			[[
      UPDATE knowledge
      SET title = ?, tags = ?, content = ?, time = ?
      WHERE id = ?
    ]],
			{
				title,
				table.concat(tags, ","),
				text,
				os.date("%Y-%m-%d %H:%M:%S"),
				id,
			}
		)

		vim.notify("已更新 #" .. id, vim.log.levels.INFO)
		return id
	else
		-- ✅ INSERT
		db:insert("knowledge", {
			time = os.date("%Y-%m-%d %H:%M:%S"),
			type = detect_type(text),
			tags = table.concat(tags, ","),
			title = title,
			content = text,
		})

		-- ✅ 关键：拿到新 id
		local row = db:eval("SELECT last_insert_rowid() as id")
		local new_id = row and row[1] and row[1].id

		vim.notify("已创建 #" .. new_id, vim.log.levels.INFO)
		return new_id
	end
end

-- =========================
-- ✅ 修复核心：window state 记住 id
-- =========================
function M.open_paste_window()
	local buf = vim.api.nvim_create_buf(false, true)

	local width = math.floor(vim.o.columns * 0.8)
	local height = math.floor(vim.o.lines * 0.8)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = 2,
		col = 2,
		border = "rounded",
		style = "minimal",
		title = "新建知识",
	})

	-- ✅ 关键：状态
	local state = {
		id = nil,
	}

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"=== Title ===",
		"",
		"",
		"=== Tags ===",
		"",
		"",
		"=== Content ===",
		"",
	})

	vim.keymap.set("n", "<C-s>", function()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

		local title = lines[2] or ""
		local tags = lines[5] or ""

		local content = table.concat(vim.list_slice(lines, 8), "\n")

		local tags_list = split_tags(tags)

		-- ✅ 关键：传 id
		local saved_id = save_content(content, {
			id = state.id,
			title = vim.trim(title) ~= "" and vim.trim(title) or nil,
			tags = #tags_list > 0 and tags_list or nil,
		})

		-- ✅ 关键：第一次保存后绑定 id
		if not state.id then
			state.id = saved_id

			-- 可选：更新标题
			vim.api.nvim_win_set_config(win, {
				title = "编辑知识 #" .. state.id,
			})
		end

		vim.notify("当前 ID: " .. tostring(state.id))
	end, { buffer = buf })

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })
end

-- =========================
-- setup
-- =========================
function M.setup()
	ensure_db()
	vim.keymap.set("n", "<leader>ip", M.open_paste_window)
end

return M
