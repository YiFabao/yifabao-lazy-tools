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

-- =========================
-- DB error handling wrapper (Issue #9)
-- =========================
local function db_safe_eval(sql, params)
	local ok, result = pcall(db.eval, db, sql, params or {})
	if not ok then
		vim.notify(
			string.format("数据库错误: %s\nSQL: %s", tostring(result), sql),
			vim.log.levels.ERROR
		)
		return nil
	end
	return result
end

local function db_safe_insert(table, data)
	local ok, result = pcall(db.insert, db, table, data)
	if not ok then
		vim.notify(
			string.format("数据库插入错误: %s\nTable: %s", tostring(result), table),
			vim.log.levels.ERROR
		)
		return nil
	end
	return result
end

-- =========================
-- Cache for type/tag detection (performance optimization)
-- =========================
local type_cache = {}
local tag_cache = {}
local CACHE_MAX_SIZE = 500

local function cache_get(cache, key)
	local result = cache[key]
	if result then
		result.access_time = os.time()
		return result.value
	end
	return nil
end

local function cache_set(cache, key, value)
	if next(cache) >= CACHE_MAX_SIZE then
		-- Simple LRU: remove oldest entry
		local oldest_key, oldest_entry = nil, nil
		for k, v in pairs(cache) do
			if not oldest_entry or v.access_time < oldest_entry.access_time then
				oldest_key = k
				oldest_entry = v
			end
		end
		if oldest_key then
			cache[oldest_key] = nil
		end
	end
	cache[key] = { value = value, access_time = os.time() }
end

local function init_db()
	ensure_dir()

	-- 更安全的打开检查
	if db and db:isopen() then
		return
	end

	db = sqlite({ uri = db_path() })
	db:open()

	db_safe_eval([[
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

	db_safe_eval([[
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

	-- 使用事务保护 + 回滚保护 (Issue #7)
	local ok, err = pcall(function()
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

		-- Triggers (always recreate to ensure they exist after rebuild)
		db:eval("DROP TRIGGER IF EXISTS knowledge_ai;")
		db:eval([[
    CREATE TRIGGER knowledge_ai AFTER INSERT ON knowledge BEGIN
      INSERT INTO knowledge_fts(rowid, title, content, tags)
      VALUES (new.id, new.title, new.content, new.tags);
    END;
  ]])

		db:eval("DROP TRIGGER IF EXISTS knowledge_ad;")
		db:eval([[
    CREATE TRIGGER knowledge_ad AFTER DELETE ON knowledge BEGIN
      INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content, tags)
      VALUES('delete', old.id, old.title, old.content, old.tags);
    END;
  ]])

		db:eval("DROP TRIGGER IF EXISTS knowledge_au;")
		db:eval([[
    CREATE TRIGGER knowledge_au AFTER UPDATE ON knowledge BEGIN
      INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content, tags)
      VALUES('delete', old.id, old.title, old.content, old.tags);
      INSERT INTO knowledge_fts(rowid, title, content, tags)
      VALUES (new.id, new.title, new.content, new.tags);
    END;
  ]])

		db:eval("COMMIT;")
	end)

	if not ok then
		db:eval("ROLLBACK;")
		vim.notify(string.format("数据库初始化失败: %s", tostring(err)), vim.log.levels.ERROR)
	end
end

local function ensure_db()
	if not db then
		init_db()
	end
	-- 检查数据库连接是否仍然有效
	if db and not db:isopen() then
		db = nil
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
	-- Escape FTS5 special characters: " ( ) * :
	query = query:gsub('["()*:]', function(c)
		return '"' .. c .. '"'
	end)
	local tokens = {}
	for word in query:gmatch("%S+") do
		table.insert(tokens, word)
	end
	return table.concat(tokens, " ")
end

local function parse_tag_query(query)
	local tag = query:match("tag:(%S+)")
	local clean = query:gsub("tag:%S+", ""):gsub("^%s+", ""):gsub("%s+$", "")
	return tag, clean
end

-- =========================
-- UI helpers (Issue #4 & #5: Extract duplicate window logic)
-- =========================

-- Structured input window config
-- @param config: { title, footer, initial_lines, width, height, on_save, on_cancel }
local function create_input_window(config)
	local state = { id = nil }
	local buf = vim.api.nvim_create_buf(false, true)
	local width = config.width or math.floor(vim.o.columns * 0.6)
	local height = config.height or 10

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded",
		style = "minimal",
		title = config.title or "输入",
		title_pos = "center",
		footer = config.footer or " <C-s> 保存     q 退出 ",
		footer_pos = "center",
	})

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, config.initial_lines or {})
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("linebreak", true, { win = win })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_set_option_value("winhighlight", "Normal:NormalFloat,FloatBorder:Special", { win = win })

	-- 光标定位到第2行（标题输入区）
	vim.api.nvim_win_set_cursor(win, { 2, 0 })
	vim.schedule(function()
		vim.cmd("startinsert")
	end)

	-- 保存
	vim.keymap.set("n", "<C-s>", function()
		if config.on_save then
			config.on_save(buf, win, state)
		end
	end, { buffer = buf })

	-- 退出
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
		if config.on_cancel then
			config.on_cancel()
		else
			vim.notify("已取消保存", vim.log.levels.INFO)
		end
	end, { buffer = buf })

	-- 支持 visual 模式下保存
	vim.keymap.set("v", "<C-s>", "<Esc><C-s>", { buffer = buf, remap = true })

	return buf, win, state
end

-- Parse structured buffer content
-- Returns: { title, tags, content_lines }
local function parse_input_buf(buf, content_marker_line)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local title = ""
	local tags = ""
	local content_start = 1

	for i, line in ipairs(lines) do
		if line == "=== Title ===" then
			title = lines[i + 1] or ""
		elseif line == "=== Tags (用逗号分隔) ===" then
			tags = lines[i + 1] or ""
		elseif line == content_marker_line then
			-- 找到分隔线后的内容
			for j = i + 1, #lines do
				if lines[j]:match("^%s*────────────────────────────────") then
					content_start = j + 1
					break
				end
			end
			break
		end
	end

	return title, tags, content_start, lines
end

-- =========================
-- type / tags detect (with caching)
-- =========================
local function detect_type(text)
	-- Check cache first
	local cache_key = text:sub(1, 100)  -- Use first 100 chars as cache key
	local cached = cache_get(type_cache, cache_key)
	if cached then
		return cached
	end

	local result
	if text:match("%d+%.%d+%.%d+%.%d+/%d+") then
		result = "ip"
	elseif text:match("SELECT%s") or text:match("INSERT%s") then
		result = "sql"
	elseif text:match("function%s") or text:match("class%s") then
		result = "code"
	elseif text:match("^https?://") then
		result = "url"
	elseif text:match("^%s*[%-%*]") or text:match("^#") then
		result = "markdown"
	else
		result = "text"
	end

	cache_set(type_cache, cache_key, result)
	return result
end

local function detect_tags(text)
	-- Check cache first
	local cache_key = text:sub(1, 100)
	local cached = cache_get(tag_cache, cache_key)
	if cached then
		return cached
	end

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

	cache_set(tag_cache, cache_key, tags)
	return tags
end

-- =========================
-- CRUD
-- =========================

local function write_history(id, title, tags, content)
	local rows = db_safe_eval("SELECT MAX(version) as v FROM knowledge_history WHERE knowledge_id = ?", { id })

	local next_version = 1
	if rows and rows[1] and rows[1].v then
		next_version = rows[1].v + 1
	end

	db_safe_eval(
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
		db_safe_eval(
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

	db_safe_insert("knowledge", {
		time = os.date("%Y-%m-%d %H:%M:%S"),
		type = detect_type(text),
		tags = tag_str,
		title = title,
		content = text,
	})

	local row = db_safe_eval("SELECT last_insert_rowid() as id")
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
	local rows = db_safe_eval("SELECT title, content FROM knowledge WHERE id = ?", { id })
	if not rows or #rows == 0 then
		vim.notify("未找到该记录 #" .. id, vim.log.levels.ERROR)
		return
	end

	local entry = rows[1]
	local preview = vim.trim(entry.title or entry.content:sub(1, 60))

	local confirm = vim.fn.confirm("确认删除知识 #" .. id .. " ?\n标题: " .. preview, "&Yes\n&No", 2)
	if confirm == 1 then
		db_safe_eval("DELETE FROM knowledge WHERE id = ?", { id })
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
	local rows = db_safe_eval([[
    SELECT id, time, type, tags, title, content
    FROM knowledge
    ORDER BY time DESC
    LIMIT ?
  ]], { limit or 100 })
	return rows_to_items(rows or {})
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

	local rows = db_safe_eval(sql, params)
	if type(rows) ~= "table" then
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

	-- 使用 getpos 获取选区（兼容性更好）
	local start_pos = vim.fn.getpos("v")
	local end_pos = vim.fn.getpos(".")
	local start_line = math.min(start_pos[2], end_pos[2])
	local end_line = math.max(start_pos[2], end_pos[2])

	local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
	if not lines or #lines == 0 then
		vim.notify("空选区", vim.log.levels.WARN)
		return
	end

	local content = table.concat(lines, "\n")
	if content:match("^%s*$") then
		vim.notify("选区为空", vim.log.levels.WARN)
		return
	end

	local detected_tags = detect_tags(content)
	local default_tags = table.concat(detected_tags, ", ")

	local initial_lines = {
		"=== Title ===",
		"",
		"",
		"=== Tags (用逗号分隔) ===",
		default_tags ~= "" and default_tags or "",
		"",
	}

	create_input_window({
		title = "新建知识",
		footer = " <C-s> 保存     q 退出 ",
		initial_lines = initial_lines,
		width = math.floor(vim.o.columns * 0.6),
		height = 10,
		on_save = function(buf, win, state)
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
		end,
	})
end

function M.paste_from_clipboard()
	local content = vim.fn.getreg("+")
	if not content or content:match("^%s*$") then
		vim.notify("剪贴板为空", vim.log.levels.WARN)
		return
	end

	local detected_tags = detect_tags(content)
	local default_tags = table.concat(detected_tags, ", ")

	local initial_lines = {
		"=== Title ===",
		"",
		"",
		"=== Tags (用逗号分隔) ===",
		default_tags ~= "" and default_tags or "",
		"",
	}

	create_input_window({
		title = " 保存知识 - 输入标题和标签 ",
		footer = " <C-s> 保存     q 退出 ",
		initial_lines = initial_lines,
		width = math.floor(vim.o.columns * 0.6),
		height = 10,
		on_save = function(buf, win, state)
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
		end,
	})
end

function M.rebuild_fts()
	ensure_db()

	-- Drop and recreate FTS table with triggers
	db:eval("DROP TABLE IF EXISTS knowledge_fts;")
	db:eval("DROP TRIGGER IF EXISTS knowledge_ai;")
	db:eval("DROP TRIGGER IF EXISTS knowledge_ad;")
	db:eval("DROP TRIGGER IF EXISTS knowledge_au;")

	db:eval([[
        CREATE VIRTUAL TABLE knowledge_fts USING fts5(
          title, content, tags,
          tokenize = 'trigram',
          content = 'knowledge',
          content_rowid = 'id'
        );
    ]])

	-- Recreate triggers
	db:eval([[
    CREATE TRIGGER knowledge_ai AFTER INSERT ON knowledge BEGIN
      INSERT INTO knowledge_fts(rowid, title, content, tags)
      VALUES (new.id, new.title, new.content, new.tags);
    END;
  ]])

	db:eval([[
    CREATE TRIGGER knowledge_ad AFTER DELETE ON knowledge BEGIN
      INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content, tags)
      VALUES('delete', old.id, old.title, old.content, old.tags);
    END;
  ]])

	db:eval([[
    CREATE TRIGGER knowledge_au AFTER UPDATE ON knowledge BEGIN
      INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content, tags)
      VALUES('delete', old.id, old.title, old.content, old.tags);
      INSERT INTO knowledge_fts(rowid, title, content, tags)
      VALUES (new.id, new.title, new.content, new.tags);
    END;
  ]])

	-- 重新填充索引
	db:eval([[
        INSERT INTO knowledge_fts(rowid, title, content, tags)
        SELECT id, title, content, tags FROM knowledge;
    ]])

	vim.notify("知识库 FTS 已重建为 trigram 模式（中文单字/子串搜索已优化）", vim.log.levels.INFO)
end

function M.open_paste_window()
	local initial_lines = {
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
	}

	local buf, win, state = create_input_window({
		title = " 粘贴并编辑知识 ",
		footer = " <C-s> 保存到知识库     q 退出 ",
		initial_lines = initial_lines,
		width = math.floor(vim.o.columns * 0.82),
		height = math.floor(vim.o.lines * 0.78),
		on_save = function(buf, win, s)
			local title, tags, content_start, lines = parse_input_buf(buf, "=== Content ===")

			local content = table.concat(vim.list_slice(lines, content_start), "\n")
			content = vim.trim(content)

			if content == "" then
				vim.notify("内容为空，未保存", vim.log.levels.WARN)
				return
			end

			local tags_list = split_tags(tags)

			local saved_id = save_content(content, {
				id = s.id,
				title = vim.trim(title) ~= "" and vim.trim(title) or nil,
				tags = #tags_list > 0 and tags_list or nil,
			})

			if not s.id then
				s.id = saved_id
			end

			vim.api.nvim_win_set_config(win, {
				title = s.id and ("编辑知识 #" .. s.id) or "新建知识",
			})

			vim.notify("已保存（未关闭窗口，可继续编辑）", vim.log.levels.INFO)
		end,
		on_cancel = function()
			vim.notify("已取消保存", vim.log.levels.INFO)
		end,
	})
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

	local rows = db_safe_eval("SELECT id, title, tags, content FROM knowledge WHERE id = ?", { id })
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

		db_safe_eval(
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
						"╭────────────────────────────────────────────────╮",
						string.format("│ ID: %-4s  Type: %-6s  Time: %-19s │", 
							tostring(value.id or ""), 
							value.type or "", 
							value.time or ""),
						string.format("│ Title: %-51s │", (value.title or ""):sub(1, 51)),
						"╰────────────────────────────────────────────────╯",
						"Tags: " .. table.concat(value.tags, ", "),
						"──────────────────────────────────────────────────",
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

				local function show_history()
					local selection = action_state.get_selected_entry()
					if not selection then
						return
					end
					actions.close(prompt_bufnr)
					vim.schedule(function()
						M.history_ui(selection.value.id)
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
				map("i", "<C-h>", show_history)
				map("n", "<C-h>", show_history)

				return true
			end,
		})
		:find()
end

-- =========================
-- migration
-- =========================
function M.migrate_from_jsonl()
	ensure_db()
	local file_path = vim.fn.stdpath("data") .. "/edit-tools/knowledge.jsonl"
	if vim.fn.filereadable(file_path) == 0 then
		vim.notify("没有 JSONL 文件", vim.log.levels.INFO)
		return
	end

	for line in io.lines(file_path) do
		local ok, obj = pcall(vim.json.decode, line)
		if ok and obj then
			db_safe_insert("knowledge", {
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

	local rows = db_safe_eval(
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

	local rows = db_safe_eval(
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
	local previewers = require("telescope.previewers")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = string.format("History #%d (共 %d 个版本)", id, #rows),
			finder = finders.new_table({
				results = rows,
				entry_maker = function(entry)
					return {
						value = entry,
						display = string.format(
							"v%-4d | %-19s | %s",
							entry.version,
							entry.time,
							(entry.title or ""):sub(1, 60)
						),
						ordinal = tostring(entry.version) .. " " .. (entry.title or ""),
					}
				end,
			}),

			sorter = conf.generic_sorter({}),

			previewer = previewers.new_buffer_previewer({
				title = "版本预览",
				define_preview = function(self, entry)
					local bufnr = self.state.bufnr
					local winid = self.state.winid
					local value = entry.value

					-- 构建预览头部
					local header = {
						"╭──────────────────────────────────────────────╮",
						string.format("│ 版本: v%-4d  时间: %-19s │", value.version, value.time),
						string.format("│ 标题: %-52s │", (value.title or ""):sub(1, 52)),
						"╰──────────────────────────────────────────────╯",
						"",
						"─── 内容预览 ───",
						"",
					}

					-- 获取内容并限制行数
					local content_lines = vim.split(value.content or "", "\n")
					local max_lines = 100
					if #content_lines > max_lines then
						table.insert(content_lines, "")
						table.insert(content_lines, string.format("... (共 %d 行，仅显示前 %d 行)", #content_lines - 2, max_lines))
					end

					vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.list_extend(header, content_lines))
					vim.api.nvim_set_option_value("filetype", "markdown", { buf = bufnr })
					vim.api.nvim_set_option_value("wrap", true, { win = winid })
					vim.api.nvim_set_option_value("linebreak", true, { win = winid })

					-- Treesitter 高亮
					pcall(function()
						vim.treesitter.start(bufnr, "markdown")
					end)
				end,
			}),

			attach_mappings = function(prompt_bufnr, map)
				local function rollback()
					local selection = action_state.get_selected_entry()
					local v = selection.value

					local confirm = vim.fn.confirm(
						string.format("确认回滚到版本 v%d?\n标题: %s", v.version, v.title or ""),
						"&Yes\n&No",
						2
					)
					if confirm == 1 then
						M.rollback(id, v.version)
						actions.close(prompt_bufnr)
					end
				end

				local function diff_with_current()
					local selection = action_state.get_selected_entry()
					if not selection then
						return
					end
					local v = selection.value

					-- 获取当前内容
					local cur_rows = db_safe_eval("SELECT content FROM knowledge WHERE id = ?", { id })
					if not cur_rows or #cur_rows == 0 then
						vim.notify("当前记录不存在", vim.log.levels.ERROR)
						return
					end
					local cur_content = cur_rows[1].content

					-- 创建 diff 窗口
					local buf1 = vim.api.nvim_create_buf(false, true)
					local buf2 = vim.api.nvim_create_buf(false, true)

					vim.api.nvim_buf_set_lines(buf1, 0, -1, false, vim.split(cur_content, "\n"))
					vim.api.nvim_buf_set_lines(buf2, 0, -1, false, vim.split(v.content, "\n"))

					local width = math.floor(vim.o.columns * 0.9)
					local height = math.floor(vim.o.lines * 0.7)
					local row = math.floor((vim.o.lines - height) / 2)
					local col = math.floor((vim.o.columns - width) / 2)

					local win = vim.api.nvim_open_win(buf1, true, {
						relative = "editor",
						width = width,
						height = height,
						row = row,
						col = col,
						border = "rounded",
						style = "minimal",
						title = string.format("Diff: 当前 vs 历史 v%d", v.version),
						title_pos = "center",
					})

					vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf1 })
					vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf2 })

					vim.cmd("vertical diffsplit " .. vim.api.nvim_buf_get_name(buf2))

					vim.keymap.set("n", "q", function()
						vim.cmd("diffoff!")
						vim.api.nvim_win_close(win, true)
						vim.api.nvim_buf_delete(buf1, { force = true })
						vim.api.nvim_buf_delete(buf2, { force = true })
					end, { buffer = buf1 })
				end

				map("i", "<CR>", rollback)
				map("n", "<CR>", rollback)
				map("i", "<C-d>", diff_with_current)
				map("n", "<C-d>", diff_with_current)
				map("i", "<C-r>", rollback)
				map("n", "<C-r>", rollback)

				return true
			end,
		})
		:find()
end

function M.diff(id, v1, v2)
	ensure_db()

	local r1 = db_safe_eval(
		[[
		SELECT content FROM knowledge_history
		WHERE knowledge_id = ? AND version = ?
	]],
		{ id, v1 }
	)

	local r2 = db_safe_eval(
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

	local rows = db_safe_eval(
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

	db_safe_eval(
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
-- Statistics (按类型/标签计数)
-- =========================
function M.statistics()
	ensure_db()

	-- 按类型统计
	local type_rows = db_safe_eval([[
		SELECT type, COUNT(*) as count 
		FROM knowledge 
		GROUP BY type 
		ORDER BY count DESC
	]])

	-- 按标签统计
	local tag_rows = db_safe_eval([[
		SELECT tags FROM knowledge WHERE tags != ''
	]])

	local tag_counts = {}
	if tag_rows then
		for _, row in ipairs(tag_rows) do
			local tags = split_tags(row.tags)
			for _, tag in ipairs(tags) do
				tag_counts[tag] = (tag_counts[tag] or 0) + 1
			end
		end
	end

	-- 总数
	local total_rows = db_safe_eval("SELECT COUNT(*) as count FROM knowledge")
	local total = total_rows and total_rows[1] and total_rows[1].count or 0

	-- 格式化输出
	local lines = {
		"=== 知识库统计 ===",
		"",
		string.format("总记录数: %d", total),
		"",
		"--- 按类型分布 ---",
	}

	if type_rows then
		for _, row in ipairs(type_rows) do
			local pct = total > 0 and string.format("%.1f%%", row.count / total * 100) or "0%"
			table.insert(lines, string.format("  %-10s %d (%s)", row.type, row.count, pct))
		end
	end

	table.insert(lines, "")
	table.insert(lines, "--- 标签 Top 10 ---")

	-- 排序标签
	local sorted_tags = {}
	for tag, count in pairs(tag_counts) do
		table.insert(sorted_tags, { tag = tag, count = count })
	end
	table.sort(sorted_tags, function(a, b) return a.count > b.count end)

	for i = 1, math.min(10, #sorted_tags) do
		table.insert(lines, string.format("  #%-15s %d", sorted_tags[i].tag, sorted_tags[i].count))
	end

	-- 显示在窗口中
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local width = 60
	local height = #lines + 2
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded",
		style = "minimal",
		title = " 知识库统计 ",
		title_pos = "center",
	})

	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(buf, { force = true })
	end, { buffer = buf })

	vim.notify("按 q 关闭窗口", vim.log.levels.INFO)
end

-- =========================
-- Export / Import
-- =========================

--- 导出知识库数据
--- @param format string "json" | "markdown" | "jsonl"
function M.export(format)
	ensure_db()
	format = format or "json"

	local rows = db_safe_eval([[
		SELECT id, time, type, tags, title, content 
		FROM knowledge 
		ORDER BY id
	]])

	if not rows or #rows == 0 then
		vim.notify("知识库为空", vim.log.levels.WARN)
		return
	end

	local export_path
	if format == "json" then
		-- 导出为 JSON 数组
		local json_data = {}
		for _, row in ipairs(rows) do
			table.insert(json_data, {
				id = row.id,
				time = row.time,
				type = row.type,
				tags = split_tags(row.tags),
				title = row.title,
				content = row.content,
			})
		end

		local json_str = vim.json.encode(json_data)
		export_path = vim.fn.expand("~/knowledge_export_" .. os.date("%Y%m%d_%H%M%S") .. ".json")
		local f = io.open(export_path, "w")
		if f then
			f:write(json_str)
			f:close()
		else
			vim.notify("无法写入文件: " .. export_path, vim.log.levels.ERROR)
			return
		end

	elseif format == "jsonl" then
		-- 导出为 JSONL (每行一个 JSON 对象)
		export_path = vim.fn.expand("~/knowledge_export_" .. os.date("%Y%m%d_%H%M%S") .. ".jsonl")
		local f = io.open(export_path, "w")
		if f then
			for _, row in ipairs(rows) do
				local line = vim.json.encode({
					id = row.id,
					time = row.time,
					type = row.type,
					tags = split_tags(row.tags),
					title = row.title,
					content = row.content,
				})
				f:write(line .. "\n")
			end
			f:close()
		else
			vim.notify("无法写入文件: " .. export_path, vim.log.levels.ERROR)
			return
		end

	elseif format == "markdown" then
		-- 导出为 Markdown 文档
		export_path = vim.fn.expand("~/knowledge_export_" .. os.date("%Y%m%d_%H%M%S") .. ".md")
		local f = io.open(export_path, "w")
		if f then
			f:write("# 知识库导出\n\n")
			f:write(string.format("导出时间: %s\n\n", os.date("%Y-%m-%d %H:%M:%S")))
			f:write(string.format("总记录数: %d\n\n", #rows))
			f:write("---\n\n")

			for _, row in ipairs(rows) do
				f:write(string.format("## [%d] %s\n\n", row.id, row.title or "Untitled"))
				f:write(string.format("- 时间: %s\n", row.time))
				f:write(string.format("- 类型: %s\n", row.type))
				if row.tags and row.tags ~= "" then
					f:write(string.format("- 标签: %s\n", row.tags))
				end
				f:write("\n")
				f:write(row.content or "")
				f:write("\n\n---\n\n")
			end
			f:close()
		else
			vim.notify("无法写入文件: " .. export_path, vim.log.levels.ERROR)
			return
		end
	else
		vim.notify("不支持的格式: " .. format .. " (支持: json, jsonl, markdown)", vim.log.levels.ERROR)
		return
	end

	vim.notify(string.format("已导出到: %s (%d 条记录)", export_path, #rows), vim.log.levels.INFO)
end

--- 导入知识库数据
--- @param file_path string 文件路径
function M.import(file_path)
	ensure_db()
	file_path = vim.fn.expand(file_path)

	if vim.fn.filereadable(file_path) == 0 then
		vim.notify("文件不存在: " .. file_path, vim.log.levels.ERROR)
		return
	end

	local ext = vim.fn.fnamemodify(file_path, ":e")
	local count = 0

	if ext == "json" then
		-- 导入 JSON 数组
		local f = io.open(file_path, "r")
		if not f then
			vim.notify("无法读取文件", vim.log.levels.ERROR)
			return
		end
		local content = f:read("*all")
		f:close()

		local ok, data = pcall(vim.json.decode, content)
		if not ok or type(data) ~= "table" then
			vim.notify("JSON 解析失败", vim.log.levels.ERROR)
			return
		end

		for _, item in ipairs(data) do
			db_safe_insert("knowledge", {
				time = item.time or os.date("%Y-%m-%d %H:%M:%S"),
				type = item.type or "text",
				tags = type(item.tags) == "table" and table.concat(item.tags, ",") or "",
				title = item.title or "",
				content = item.content or "",
			})
			count = count + 1
		end

	elseif ext == "jsonl" then
		-- 导入 JSONL
		for line in io.lines(file_path) do
			local ok, obj = pcall(vim.json.decode, line)
			if ok and obj then
				db_safe_insert("knowledge", {
					time = obj.time or os.date("%Y-%m-%d %H:%M:%S"),
					type = obj.type or "text",
					tags = type(obj.tags) == "table" and table.concat(obj.tags, ",") or "",
					title = obj.title or "",
					content = obj.content or "",
				})
				count = count + 1
			end
		end

	elseif ext == "md" then
		vim.notify("Markdown 导入暂不支持", vim.log.levels.WARN)
		return
	else
		vim.notify("不支持的文件格式: " .. ext, vim.log.levels.ERROR)
		return
	end

	vim.notify(string.format("已导入 %d 条记录", count), vim.log.levels.INFO)
end

-- =========================
-- setup
-- =========================
function M.setup(opts)
	opts = opts or {}
	ensure_db()

	-- 默认键映射
	local default_keymaps = {
		save_visual = "<leader>is",
		save_clipboard = "<leader>iv",
		paste_window = "<leader>ip",
		knowledge_search = "<leader>ik",
		migrate = "<leader>im",
		rebuild_fts = "<leader>ir",
		history = "<leader>ih",
		statistics = "<leader>ist",
		export = "<leader>ie",
		import = "<leader>ii",
	}

	-- 合并用户配置
	local keymaps = vim.tbl_extend("keep", opts.keymaps or {}, default_keymaps)

	vim.keymap.set("v", keymaps.save_visual, M.save_visual_selection, { desc = "Save visual selection" })
	vim.keymap.set("n", keymaps.save_clipboard, M.paste_from_clipboard, { desc = "Save clipboard" })
	vim.keymap.set("n", keymaps.paste_window, M.open_paste_window, { desc = "Paste window" })
	vim.keymap.set("n", keymaps.knowledge_search, M.open, { desc = "Knowledge search" })
	vim.keymap.set("n", keymaps.migrate, M.migrate_from_jsonl, { desc = "Migrate JSONL" })
	vim.keymap.set("n", keymaps.rebuild_fts, M.rebuild_fts, { desc = "Rebuild FTS index (trigram)" })
	vim.keymap.set("n", keymaps.history, function()
		local id = vim.fn.input("Knowledge ID: ")
		M.history_ui(tonumber(id))
	end, { desc = "View history" })
	vim.keymap.set("n", keymaps.statistics, M.statistics, { desc = "Knowledge statistics" })
	vim.keymap.set("n", keymaps.export, function()
		local format = vim.fn.input("Format (json/jsonl/markdown): ", "json")
		if format ~= "" then
			M.export(format)
		end
	end, { desc = "Export knowledge base" })
	vim.keymap.set("n", keymaps.import, function()
		local path = vim.fn.input("File path: ", "~/knowledge_export.json")
		if path ~= "" then
			M.import(path)
		end
	end, { desc = "Import knowledge base" })

	-- 添加命令支持
	vim.api.nvim_create_user_command("KnowledgeList", function()
		M.open()
	end, { desc = "Open knowledge base search" })

	vim.api.nvim_create_user_command("KnowledgeStats", function()
		M.statistics()
	end, { desc = "Show knowledge statistics" })

	vim.api.nvim_create_user_command("KnowledgeExport", function(opts)
		local format = opts.args ~= "" and opts.args or "json"
		M.export(format)
	end, { nargs = "?", desc = "Export knowledge base (json/jsonl/markdown)" })

	vim.api.nvim_create_user_command("KnowledgeImport", function(opts)
		if opts.args == "" then
			vim.notify("请提供文件路径", vim.log.levels.ERROR)
			return
		end
		M.import(opts.args)
	end, { nargs = 1, desc = "Import knowledge base from file" })

	vim.api.nvim_create_user_command("KnowledgeRebuildFTS", function()
		M.rebuild_fts()
	end, { desc = "Rebuild FTS index" })
end

return M
