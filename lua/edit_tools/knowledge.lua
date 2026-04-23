local M = {}
local sqlite = require("sqlite")
local db = nil -- db 由ensure_db / init_db 保证非nil

-- =========================
-- path / db lifecycle
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

	-- 更安全的打开检查
	if db and db:isopen() then
		return
	end

	db = sqlite({ uri = db_path() })
	db:open()

	db:eval([[
  CREATE TABLE IF NOT EXISTS knowledge_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    knowledge_id INTEGER NOT NULL,
    version INTEGER NOT NULL,
    time TEXT NOT NULL,
    type TEXT NOT NULL,
    tags TEXT DEFAULT '',
    title TEXT DEFAULT '',
    content TEXT NOT NULL
  );
  ]])

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

	-- 使用事务保护
	db:eval("BEGIN TRANSACTION;")

	-- 切换为 trigram tokenizer（支持中文子串搜索）
	db:eval([[
    CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
      title, content, tags,
      tokenize = 'trigram',
      content = 'knowledge',
      content_rowid = 'id'
    );
  ]])

	-- Triggers
	db:eval([[
    CREATE TRIGGER IF NOT EXISTS knowledge_ai AFTER INSERT ON knowledge BEGIN
      INSERT INTO knowledge_fts(rowid, title, content, tags)
      VALUES (new.id, new.title, new.content, new.tags);
    END;
  ]])

	db:eval([[
    CREATE TRIGGER IF NOT EXISTS knowledge_ad AFTER DELETE ON knowledge BEGIN
      INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content, tags)
      VALUES('delete', old.id, old.title, old.content, old.tags);
    END;
  ]])

	db:eval([[
    CREATE TRIGGER IF NOT EXISTS knowledge_au AFTER UPDATE ON knowledge BEGIN
      INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content, tags)
      VALUES('delete', old.id, old.title, old.content, old.tags);
      INSERT INTO knowledge_fts(rowid, title, content, tags)
      VALUES (new.id, new.title, new.content, new.tags);
    END;
  ]])

	db:eval("COMMIT;")
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

local function rows_to_items(rows)
	if type(rows) ~= "table" then
		return {}
	end
	local items = {}
	for _, row in ipairs(rows) do
		table.insert(items, {
			id = row.id,
			time = row.time,
			type = row.type,
			tags = split_tags(row.tags),
			title = row.title or "",
			text = row.content or "",
			raw = row,
		})
	end
	return items
end

local function escape_fts(query)
	query = vim.trim(query or "")
	if query == "" then
		return ""
	end
	local tokens = {}
	for word in query:gmatch("%S+") do
		table.insert(tokens, word) -- 去掉 *
	end
	return table.concat(tokens, " ") -- 空格分隔在 FTS5 中默认是 AND
end

local function parse_tag_query(query)
	local tag = query:match("tag:(%S+)")
	local clean = query:gsub("tag:%S+", ""):gsub("^%s+", ""):gsub("%s+$", "")
	return tag, clean
end

-- =========================
-- type / tags detect
-- =========================
local function detect_type(text)
	if text:match("%d+%.%d+%.%d+%.%d+/%d+") then
		return "ip"
	end
	if text:match("SELECT%s") or text:match("INSERT%s") then
		return "sql"
	end
	if text:match("function%s") or text:match("class%s") then
		return "code"
	end
	if text:match("^https?://") then
		return "url"
	end
	if text:match("^%s*[%-%*]") or text:match("^#") then
		return "markdown"
	end
	return "text"
end

local function detect_tags(text)
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

-- =========================
-- CRUD
-- =========================

local function write_history(id, title, tags, content)
	local rows = db:eval("SELECT MAX(version) as v FROM knowledge_history WHERE knowledge_id = ?", { id })

	local next_version = 1
	if rows and rows[1] and rows[1].v then
		next_version = rows[1].v + 1
	end

	db:eval(
		[[
  INSERT INTO knowledge_history
  (knowledge_id, version, time, type, tags, title, content)
  VALUES (?, ?, ?, ?, ?, ?, ?)
]],
		{
			id,
			next_version,
			os.date("%Y-%m-%d %H:%M:%S"),
			detect_type(content),
			tags,
			title,
			content,
		}
	)
end

local function save_content(content, opts)
	ensure_db()
	if not content or content == "" then
		vim.notify("没有内容可以保存", vim.log.levels.WARN)
		return
	end

	opts = opts or {}
	local id = opts.id

	local lines = vim.split(content, "\n")
	local text = table.concat(lines, "\n")

	local title = opts.title
	local tags = opts.tags

	if not title or vim.trim(title) == "" then
		title = lines[1] and lines[1]:sub(1, 80) or "Untitled"
	end

	if not tags then
		tags = detect_tags(text)
		if type(tags) == "string" then
			tags = split_tags(tags)
		end
	end

	local tag_str = table.concat(tags, ",")

	if id then
		write_history(id, title, table.concat(tags, ","), text)
		db:eval(
			[[
			UPDATE knowledge
			SET title = ?, tags = ?, content = ?, time = ?, type = ?
			WHERE id = ?
		]],
			{
				title,
				tag_str,
				text,
				os.date("%Y-%m-%d %H:%M:%S"),
				detect_type(text),
				id,
			}
		)

		vim.notify("已更新 #" .. id, vim.log.levels.INFO)
		return id
	end

	db:insert("knowledge", {
		time = os.date("%Y-%m-%d %H:%M:%S"),
		type = detect_type(text),
		tags = tag_str,
		title = title,
		content = text,
	})

	local row = db:eval("SELECT last_insert_rowid() as id")
	local new_id = row and row[1] and row[1].id
	if not new_id then
		vim.notify("insert knowledge failed: no row id", vim.log.levels.ERROR)
		return
	end
	write_history(new_id, title, table.concat(tags, ","), text)

	vim.notify("已创建 #" .. tostring(new_id), vim.log.levels.INFO)
	return new_id
end

local function delete_entry(id)
	ensure_db()
	id = tonumber(id)
	if not id then
		return
	end

	-- 获取条目信息用于确认提示
	local rows = db:eval("SELECT title, content FROM knowledge WHERE id = ?", { id })
	if not rows or #rows == 0 then
		vim.notify("未找到该记录 #" .. id, vim.log.levels.ERROR)
		return
	end

	local entry = rows[1]
	local preview = vim.trim(entry.title or entry.content:sub(1, 60))

	local confirm = vim.fn.confirm("确认删除知识 #" .. id .. " ?\n标题: " .. preview, "&Yes\n&No", 2)
	if confirm == 1 then
		db:eval("DELETE FROM knowledge WHERE id = ?", { id })
		vim.notify("已删除 #" .. id, vim.log.levels.INFO)

		-- 如果在 Telescope 中删除，刷新列表
		if M.open then
			vim.schedule(M.open)
		end
	else
		vim.notify("已取消删除", vim.log.levels.INFO)
	end
end

local function list_recent(limit)
	ensure_db()
	local rows = db:eval(string.format(
		[[
    SELECT id, time, type, tags, title, content
    FROM knowledge
    ORDER BY time DESC
    LIMIT %d
  ]],
		limit or 100
	))
	return rows_to_items(rows)
end

local function search_db(query, limit)
	ensure_db()
	if not query or query == "" then
		return list_recent(limit)
	end

	local tag, clean = parse_tag_query(query)
	local conditions = {}
	local params = {}

	if clean ~= "" then
		table.insert(
			conditions,
			[[
      k.id IN (
        SELECT rowid FROM knowledge_fts WHERE knowledge_fts MATCH ?
      )
    ]]
		)
		table.insert(params, escape_fts(clean))
	end

	if tag then
		table.insert(conditions, "k.tags LIKE ?")
		table.insert(params, "%" .. tag .. "%")
	end

	local where_sql = #conditions > 0 and "WHERE " .. table.concat(conditions, " AND ") or ""
	local sql = string.format(
		[[
    SELECT k.id, k.time, k.type, k.tags, k.title, k.content
    FROM knowledge k
    %s
    ORDER BY k.time DESC
    LIMIT ?
  ]],
		where_sql
	)

	table.insert(params, limit or 100)

	local ok, rows = pcall(db.eval, db, sql, params)
	if not ok or type(rows) ~= "table" then
		return {}
	end
	return rows_to_items(rows)
end

-- =========================
-- UI save methods
-- =========================
function M.save_visual_selection()
	local state = { id = nil }
	local mode = vim.fn.mode()
	if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
		vim.notify("请在 visual 模式下使用", vim.log.levels.WARN)
		return
	end

	local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
	if not lines or #lines == 0 then
		vim.notify("空选区", vim.log.levels.WARN)
		return
	end

	local content = table.concat(lines, "\n")
	if content:match("^%s*$") then
		vim.notify("选区为空", vim.log.levels.WARN)
		return
	end

	-- 创建输入窗口
	local buf = vim.api.nvim_create_buf(false, true)
	local width = math.floor(vim.o.columns * 0.6)
	local height = 10

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded",
		style = "minimal",
		title = state.id and ("编辑知识 #" .. state.id) or "新建知识",
		title_pos = "center",
		footer = " <C-s> 保存     q 退出 ",
		footer_pos = "center",
	})

	-- 自动检测的标签作为默认值
	local detected_tags = detect_tags(content)
	local default_tags = table.concat(detected_tags, ", ")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"=== Title ===",
		"",
		"",
		"=== Tags (用逗号分隔) ===",
		default_tags ~= "" and default_tags or "",
		"",
	})

	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("linebreak", true, { win = win })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_set_option_value("winhighlight", "Normal:NormalFloat,FloatBorder:Special", { win = win })

	-- 光标定位到标题输入区
	vim.api.nvim_win_set_cursor(win, { 2, 0 })
	vim.schedule(function()
		vim.cmd("startinsert")
	end)

	-- 保存
	vim.keymap.set("n", "<C-s>", function()
		local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local title = buf_lines[2] or ""
		local tags = buf_lines[5] or ""

		local tags_list = split_tags(tags)

		local saved_id = save_content(content, {
			id = state.id,
			title = vim.trim(title) ~= "" and vim.trim(title) or nil,
			tags = #tags_list > 0 and tags_list or nil,
		})

		if not state.id then
			state.id = saved_id
		end

		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
	end, { buffer = buf })

	-- 退出
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
		vim.notify("已取消保存", vim.log.levels.INFO)
	end, { buffer = buf })
end

function M.paste_from_clipboard()
	local state = { id = nil }
	local content = vim.fn.getreg("+")
	if not content or content:match("^%s*$") then
		vim.notify("剪贴板为空", vim.log.levels.WARN)
		return
	end

	-- 创建输入窗口
	local buf = vim.api.nvim_create_buf(false, true)
	local width = math.floor(vim.o.columns * 0.6)
	local height = 10

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded",
		style = "minimal",
		title = " 保存知识 - 输入标题和标签 ",
		title_pos = "center",
		footer = " <C-s> 保存     q 退出 ",
		footer_pos = "center",
	})

	-- 自动检测的标签作为默认值
	local detected_tags = detect_tags(content)
	local default_tags = table.concat(detected_tags, ", ")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"=== Title ===",
		"",
		"",
		"=== Tags (用逗号分隔) ===",
		default_tags ~= "" and default_tags or "",
		"",
	})

	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("linebreak", true, { win = win })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_set_option_value("winhighlight", "Normal:NormalFloat,FloatBorder:Special", { win = win })

	-- 光标定位到标题输入区
	vim.api.nvim_win_set_cursor(win, { 2, 0 })
	vim.schedule(function()
		vim.cmd("startinsert")
	end)

	-- 保存
	vim.keymap.set("n", "<C-s>", function()
		local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local title = buf_lines[2] or ""
		local tags = buf_lines[5] or ""

		local tags_list = split_tags(tags)

		local saved_id = save_content(content, {
			id = state.id,
			title = vim.trim(title) ~= "" and vim.trim(title) or nil,
			tags = #tags_list > 0 and tags_list or nil,
		})

		if not state.id then
			state.id = saved_id
		end

		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
	end, { buffer = buf })

	-- 退出
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
		vim.notify("已取消保存", vim.log.levels.INFO)
	end, { buffer = buf })
end

function M.rebuild_fts()
	ensure_db()
	db:eval("DROP TABLE IF EXISTS knowledge_fts;")

	db:eval([[
        CREATE VIRTUAL TABLE knowledge_fts USING fts5(
          title, content, tags,
          tokenize = 'trigram',
          content = 'knowledge',
          content_rowid = 'id'
        );
    ]])

	-- 重新填充索引
	db:eval([[
        INSERT INTO knowledge_fts(rowid, title, content, tags)
        SELECT id, title, content, tags FROM knowledge;
    ]])

	vim.notify("知识库 FTS 已重建为 trigram 模式（中文单字/子串搜索已优化）", vim.log.levels.INFO)
end

function M.open_paste_window()
	local state = { id = nil } -- ✅ 新增
	local buf = vim.api.nvim_create_buf(false, true)

	-- 窗口尺寸（更宽更高，视觉更好）
	local width = math.floor(vim.o.columns * 0.82)
	local height = math.floor(vim.o.lines * 0.78)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded", -- 圆角边框，更现代
		style = "minimal",
		title = " 粘贴并编辑知识 ",
		title_pos = "center",
		footer = " <C-s> 保存到知识库     q 退出 ",
		footer_pos = "center",
	})

	-- 干净且友好的初始内容（包含标题和标签输入区）
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"=== Title ===",
		"",
		"",
		"=== Tags (用逗号分隔) ===",
		"",
		"",
		"=== Content ===",
		"请直接在这里粘贴内容，然后可以随意编辑：",
		"",
		"────────────────────────────────────────────────────────────",
		"",
	})

	-- 美化设置
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("linebreak", true, { win = win })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

	-- 可选：给窗口添加一点背景高亮（让它更显眼）
	vim.api.nvim_set_option_value("winhighlight", "Normal:NormalFloat,FloatBorder:Special", { win = win })

	-- 光标定位到标题输入区
	vim.api.nvim_win_set_cursor(win, { 2, 0 })
	vim.schedule(function()
		vim.cmd("startinsert")
	end)

	-- ====================== 保存 ======================
	vim.keymap.set("n", "<C-s>", function()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

		-- 解析标题
		local title = ""
		local tags = ""
		local content_start = 1

		for i, line in ipairs(lines) do
			if line == "=== Title ===" then
				title = lines[i + 1] or ""
			elseif line == "=== Tags (用逗号分隔) ===" then
				tags = lines[i + 1] or ""
			elseif line == "=== Content ===" then
				-- 找到分隔线后的内容
				for j = i + 1, #lines do
					if
						lines[j]:match(
							"^%s*────────────────────────────────"
						)
					then
						content_start = j + 1
						break
					end
				end
				break
			end
		end

		local content = table.concat(vim.list_slice(lines, content_start), "\n")
		content = vim.trim(content)

		if content == "" then
			vim.notify("内容为空，未保存", vim.log.levels.WARN)
			return
		end

		-- 处理 tags
		local tags_list = split_tags(tags)

		local saved_id = save_content(content, {
			id = state.id, -- ✅ 关键
			title = vim.trim(title) ~= "" and vim.trim(title) or nil,
			tags = #tags_list > 0 and tags_list or nil,
		})

		-- ✅ 第一次保存后绑定 id
		if not state.id then
			state.id = saved_id
		end

		vim.api.nvim_win_set_config(win, {
			title = state.id and ("编辑知识 #" .. state.id) or "新建知识",
		})

		vim.notify("已保存（未关闭窗口，可继续编辑）", vim.log.levels.INFO)
		-- vim.api.nvim_win_close(win, true)
		-- vim.api.nvim_buf_delete(buf, { force = true })
	end, { buffer = buf })

	-- ====================== 退出 ======================
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
	end, { buffer = buf })

	-- 支持 visual 模式下保存
	vim.keymap.set("v", "<C-s>", "<Esc><C-s>", { buffer = buf, remap = true })
end

-- =========================
-- Edit entry
-- =========================
function M.edit(id)
	id = tonumber(id)
	if not id then
		vim.notify("无效的 ID", vim.log.levels.ERROR)
		return
	end

	ensure_db()

	local rows = db:eval("SELECT id, title, tags, content FROM knowledge WHERE id = ?", { id })
	if not rows or #rows == 0 then
		vim.notify("未找到该记录 #" .. id, vim.log.levels.ERROR)
		return
	end

	local entry = rows[1]

	local buf = vim.api.nvim_create_buf(false, true)
	local width = math.floor(vim.o.columns * 0.8)
	local height = math.floor(vim.o.lines * 0.85)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded",
		style = "minimal",
		title = " 编辑知识 #" .. id,
		title_pos = "center",
		footer = " <C-s> 保存     q 返回列表 ",
		footer_pos = "center",
	})

	local edit_lines = {
		"=== Title ===",
		entry.title or "",
		"",
		"=== Tags (用逗号分隔) ===",
		entry.tags or "",
		"",
		"=== Content (支持 Markdown) ===",
	}
	vim.list_extend(edit_lines, vim.split(entry.content or "", "\n"))

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, edit_lines)

	-- 设置选项
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("linebreak", true, { win = win })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

	-- 保存
	vim.keymap.set("n", "<C-s>", function()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local title = ""
		local tags = ""
		local content_start = 1

		for i, line in ipairs(lines) do
			if line == "=== Title ===" then
				title = lines[i + 1] or ""
			elseif line == "=== Tags (用逗号分隔) ===" then
				tags = lines[i + 1] or ""
			elseif line == "=== Content (支持 Markdown) ===" then
				content_start = i + 1
				break
			end
		end

		local content = table.concat(vim.list_slice(lines, content_start), "\n")

		-- 记录历史
		write_history(id, vim.trim(title), vim.trim(tags), content)

		db:eval(
			[[
      UPDATE knowledge
      SET title = ?,
          tags = ?,
          content = ?,
          time = ?
      WHERE id = ?
    ]],
			{
				vim.trim(title),
				vim.trim(tags),
				content,
				os.date("%Y-%m-%d %H:%M:%S"),
				id,
			}
		)

		vim.notify("知识 #" .. id .. " 已更新", vim.log.levels.INFO)

		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })

		vim.schedule(function()
			if M.open then
				M.open()
			end
		end)
	end, { buffer = buf })

	-- 退出并返回列表
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
		vim.schedule(function()
			if M.open then
				M.open()
			end
		end)
	end, { buffer = buf })

	vim.api.nvim_win_set_cursor(win, { 2, 0 })
end

-- =========================
-- telescope
-- =========================
function M.open()
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local previewers = require("telescope.previewers")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "Knowledge Base",
			finder = finders.new_dynamic({
				fn = function(prompt)
					return search_db(prompt, 100)
				end,
				entry_maker = function(entry)
					local preview = entry.text:gsub("\n", " "):sub(1, 80)
					return {
						value = entry,
						display = string.format(
							"%-19s %-8s %-20s %s",
							entry.time,
							entry.type,
							table.concat(entry.tags, ","),
							preview
						),
						ordinal = table.concat({
							entry.title,
							entry.text,
							table.concat(entry.tags, " "),
						}, " "),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				define_preview = function(self, entry)
					local bufnr = self.state.bufnr
					local winid = self.state.winid
					local value = entry.value

					local header = {
						"=== Knowledge Preview ===",
						"Time : " .. (value.time or ""),
						"Type : " .. (value.type or ""),
						"Tags : " .. table.concat(value.tags, ", "),
						"Title: " .. (value.title or ""),
						"ID   : " .. (value.id or ""),
						"",
						"──────────────────────────────",
						"",
					}

					local content_lines = vim.split(value.text or "", "\n")
					vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.list_extend(header, content_lines))

					vim.api.nvim_set_option_value("filetype", "markdown", { buf = bufnr })

					if winid and vim.api.nvim_win_is_valid(winid) then
						vim.api.nvim_set_option_value("wrap", true, { win = winid })
						vim.api.nvim_set_option_value("linebreak", true, { win = winid })
					end

					-- Treesitter 高亮
					pcall(function()
						vim.treesitter.start(bufnr, "markdown")
						local parser = vim.treesitter.get_parser(bufnr, "markdown")
						if parser then
							parser:parse(true)
						end
					end)
				end,
			}),

			attach_mappings = function(prompt_bufnr, map)
				local function insert_entry()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					vim.api.nvim_put(vim.split(selection.value.text, "\n"), "c", true, true)
				end

				local function delete_current()
					local selection = action_state.get_selected_entry()
					local id = selection.value.id
					actions.close(prompt_bufnr)
					vim.schedule(function()
						delete_entry(id)
					end)
				end

				local function edit_current()
					local selection = action_state.get_selected_entry()
					if not selection then
						return
					end
					actions.close(prompt_bufnr)
					vim.schedule(function()
						M.edit(selection.value.id)
					end)
				end

				map("i", "<CR>", insert_entry)
				map("n", "<CR>", insert_entry)
				map("i", "dd", delete_current)
				map("n", "dd", delete_current)
				map("i", "<C-e>", edit_current)
				map("n", "<C-e>", edit_current)
				map("i", "ee", edit_current)
				map("n", "ee", edit_current)

				return true
			end,
		})
		:find()
end

-- =========================
-- migration
-- =========================
function M.migrate_from_jsonl()
	-- ...（你的原代码基本不变，可保留）
	ensure_db()
	local file_path = vim.fn.stdpath("data") .. "/edit-tools/knowledge.jsonl"
	if vim.fn.filereadable(file_path) == 0 then
		vim.notify("没有 JSONL 文件", vim.log.levels.INFO)
		return
	end

	for line in io.lines(file_path) do
		local ok, obj = pcall(vim.json.decode, line)
		if ok and obj then
			db:insert("knowledge", {
				time = obj.time or os.date("%Y-%m-%d %H:%M:%S"),
				type = obj.type or "text",
				tags = table.concat(obj.tags or {}, ","),
				title = obj.title or "",
				content = obj.content or "",
			})
		end
	end
	vim.notify("JSONL 迁移完成", vim.log.levels.INFO)
end

-- 查看历史
function M.history(id)
	ensure_db()

	local rows = db:eval(
		[[
		SELECT version, time, title, content
		FROM knowledge_history
		WHERE knowledge_id = ?
		ORDER BY version DESC
	]],
		{ id }
	)

	for _, r in ipairs(rows or {}) do
		print(string.format("#v%d %s", r.version, r.time))
	end
end

function M.history_ui(id)
	ensure_db()

	local rows = db:eval(
		[[
		SELECT version, time, title, content
		FROM knowledge_history
		WHERE knowledge_id = ?
		ORDER BY version DESC
	]],
		{ id }
	)

	if not rows or #rows == 0 then
		vim.notify("没有历史版本", vim.log.levels.WARN)
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "History #" .. id,
			finder = finders.new_table({
				results = rows,
				entry_maker = function(entry)
					return {
						value = entry,
						display = string.format("v%-3d  %s  %s", entry.version, entry.time, (entry.title or "")),
						ordinal = tostring(entry.version),
					}
				end,
			}),

			sorter = conf.generic_sorter({}),

			attach_mappings = function(prompt_bufnr, map)
				local function preview_version()
					local selection = action_state.get_selected_entry()
					local v = selection.value

					-- diff preview（简单版）
					local buf = vim.api.nvim_create_buf(false, true)
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(v.content, "\n"))

					vim.api.nvim_open_win(buf, true, {
						relative = "editor",
						width = math.floor(vim.o.columns * 0.8),
						height = math.floor(vim.o.lines * 0.8),
						border = "rounded",
					})
				end

				local function rollback()
					local selection = action_state.get_selected_entry()
					local v = selection.value

					M.rollback(id, v.version)
					actions.close(prompt_bufnr)
				end

				map("i", "<CR>", preview_version)
				map("n", "<CR>", preview_version)

				map("i", "<C-r>", rollback)
				map("n", "<C-r>", rollback)

				return true
			end,
		})
		:find()
end

function M.diff(id, v1, v2)
	ensure_db()

	local r1 = db:eval(
		[[
		SELECT content FROM knowledge_history
		WHERE knowledge_id = ? AND version = ?
	]],
		{ id, v1 }
	)

	local r2 = db:eval(
		[[
		SELECT content FROM knowledge_history
		WHERE knowledge_id = ? AND version = ?
	]],
		{ id, v2 }
	)

	if not r1 or not r2 then
		vim.notify("版本不存在", vim.log.levels.ERROR)
		return
	end

	local f1 = vim.split(r1[1].content, "\n")
	local f2 = vim.split(r2[1].content, "\n")

	-- 直接用 vim diff
	local buf1 = vim.api.nvim_create_buf(false, true)
	local buf2 = vim.api.nvim_create_buf(false, true)

	vim.api.nvim_buf_set_lines(buf1, 0, -1, false, f1)
	vim.api.nvim_buf_set_lines(buf2, 0, -1, false, f2)

	vim.cmd("vertical diffsplit")
	vim.api.nvim_set_current_buf(buf1)
	vim.cmd("vert diffsplit")
	vim.api.nvim_set_current_buf(buf2)
end

-- 回退
function M.rollback(id, version)
	ensure_db()

	local rows = db:eval(
		[[
		SELECT * FROM knowledge_history
		WHERE knowledge_id = ? AND version = ?
	]],
		{ id, version }
	)

	if not rows or #rows == 0 then
		vim.notify("版本不存在", vim.log.levels.ERROR)
		return
	end

	local v = rows[1]

	db:eval(
		[[
		UPDATE knowledge
		SET title=?, tags=?, content=?, time=?
		WHERE id=?
	]],
		{
			v.title,
			v.tags,
			v.content,
			os.date("%Y-%m-%d %H:%M:%S"),
			id,
		}
	)

	vim.notify("已回滚到 v" .. version)
end

-- =========================
-- setup
-- =========================
function M.setup()
	ensure_db()
	vim.keymap.set("v", "<leader>is", M.save_visual_selection, { desc = "Save visual selection" })
	vim.keymap.set("n", "<leader>iv", M.paste_from_clipboard, { desc = "Save clipboard" })
	vim.keymap.set("n", "<leader>ip", M.open_paste_window, { desc = "Paste window" })
	vim.keymap.set("n", "<leader>ik", M.open, { desc = "Knowledge search" })
	vim.keymap.set("n", "<leader>im", M.migrate_from_jsonl, { desc = "Migrate JSONL" })
	vim.keymap.set("n", "<leader>ir", M.rebuild_fts, { desc = "Rebuild FTS index (trigram)" })
	vim.keymap.set("n", "<leader>ih", function()
		local id = vim.fn.input("Knowledge ID: ")
		M.history_ui(tonumber(id))
	end, { desc = "history" })
end

return M
