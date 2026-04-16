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
	-- db:eval("DROP TABLE IF EXISTS knowledge_fts;")

	db:eval([[
    CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
      title, content, tags,
      tokenize = 'unicode61 remove_diacritics 0',
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

	-- 自动重建 FTS 索引（首次切换 tokenizer 时重要）
	-- db:eval([[
	--    INSERT INTO knowledge_fts(rowid, title, content, tags)
	--    SELECT id, title, content, tags FROM knowledge
	--    WHERE id NOT IN (SELECT rowid FROM knowledge_fts);
	--  ]])
	-- 因为是新数据库，暂时没有数据，不需要重建索引
	-- 等你保存几条数据后，触发器会自动同步

	db:eval("COMMIT;")

	vim.notify("知识库数据库已重新创建（trigram FTS 已启用）", vim.log.levels.INFO)
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
	-- 对中文和英文都更友好：每个词后面加 *
	local tokens = {}
	for word in query:gmatch("%S+") do
		table.insert(tokens, word .. "*")
	end
	return table.concat(tokens, " ")
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
local function save_content(content)
	ensure_db()
	if not content or content == "" then
		vim.notify("没有内容可以保存", vim.log.levels.WARN)
		return
	end

	local lines = vim.split(content, "\n")
	local text = table.concat(lines, "\n")
	local tags = detect_tags(text)

	db:insert("knowledge", {
		time = os.date("%Y-%m-%d %H:%M:%S"),
		type = detect_type(text),
		tags = table.concat(tags, ","),
		title = lines[1] and lines[1]:sub(1, 80) or "Pasted Content",
		content = text,
	})

	vim.notify("知识已保存", vim.log.levels.INFO)
end

local function delete_entry(id)
	ensure_db()
	id = tonumber(id)
	if not id then
		return
	end

	db:eval("DELETE FROM knowledge WHERE id = ?", { id })
	vim.notify("已删除 #" .. id, vim.log.levels.INFO)
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

	save_content(content)
end

function M.paste_from_clipboard()
	save_content(vim.fn.getreg("+"))
end

function M.open_paste_window()
	-- ...（你的原代码保持不变）
	local buf = vim.api.nvim_create_buf(false, true)
	local width = math.floor(vim.o.columns * 0.7)
	local height = math.floor(vim.o.lines * 0.6)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded",
		style = "minimal",
	})

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"=== 粘贴知识窗口 ===",
		"",
		"下面开始输入",
		"",
	})
	vim.api.nvim_win_set_cursor(win, { 4, 0 })

	vim.keymap.set("n", "<C-s>", function()
		local lines = vim.api.nvim_buf_get_lines(buf, 3, -1, false)
		save_content(table.concat(lines, "\n"))
		vim.api.nvim_buf_delete(buf, { force = true })
	end, { buffer = buf })

	vim.keymap.set("n", "q", function()
		vim.api.nvim_buf_delete(buf, { force = true })
	end, { buffer = buf })
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

	-- 退出
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
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
					delete_entry(selection.value.id)
					actions.close(prompt_bufnr)
					vim.schedule(M.open)
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
end

return M
