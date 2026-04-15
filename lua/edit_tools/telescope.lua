local M = {}

local function get_file()
	return vim.fn.stdpath("data") .. "/edit-tools/history.jsonl"
end

-- 读取 JSONL
local function parse_file()
	local file = io.open(get_file(), "r")
	if not file then
		return {}
	end

	local items = {}

	for line in file:lines() do
		local ok, obj = pcall(vim.json.decode, line)
		if ok and obj then
			table.insert(items, obj)
		end
	end

	file:close()
	return items
end

-- 搜索匹配
local function match(item, query)
	if not query or query == "" then
		return true
	end

	local q = query:lower()

	local text = table.concat(item.content or {}, " "):lower()
	local type = (item.type or ""):lower()

	return text:find(q, 1, true) or type:find(q, 1, true)
end

-- 高亮函数（类似搜索引擎）
local function highlight_text(text, query)
	if not query or query == "" then
		return { { text, "Normal" } }
	end

	local result = {}

	local lower_text = text:lower()
	local lower_query = query:lower()

	local i = 1

	while true do
		local s, e = lower_text:find(lower_query, i, true)
		if not s then
			break
		end

		if s > i then
			table.insert(result, {
				text:sub(i, s - 1),
				"Normal",
			})
		end

		table.insert(result, {
			text:sub(s, e),
			"TelescopeMatching",
		})

		i = e + 1
	end

	if i <= #text then
		table.insert(result, {
			text:sub(i),
			"Normal",
		})
	end

	return result
end

function M.open(query_arg)
	local items = parse_file()

	local filtered = {}

	for _, item in ipairs(items) do
		if match(item, query_arg) then
			table.insert(filtered, item)
		end
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "Edit Tools History",
			finder = finders.new_table({
				results = filtered,

				entry_maker = function(entry)
					local text = table.concat(entry.content or {}, " ")
					local query = vim.fn.getreg("/") -- Telescope 搜索词

					return {
						value = entry,

						display = function()
							return {
								{ string.format("[%s] %-5s ", entry.time, entry.type), "Comment" },
								unpack(highlight_text(text, query)),
							}
						end,

						ordinal = text .. " " .. entry.type,
					}
				end,
			}),

			sorter = conf.generic_sorter({}),

			attach_mappings = function(prompt_bufnr, map)
				local function copy()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)

					if not selection then
						return
					end

					local text = table.concat(selection.value.content or {}, "\n")

					vim.fn.setreg("+", text)
					vim.notify("Copied snippet", vim.log.levels.INFO)
				end

				map("i", "<CR>", copy)
				map("n", "<CR>", copy)

				return true
			end,
		})
		:find()
end

-- command: :History
vim.api.nvim_create_user_command("History", function(opts)
	require("edit_tools.telescope").open(opts.args)
end, {
	nargs = "*",
})

return M
