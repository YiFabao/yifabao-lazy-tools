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

function M.open(query_arg)
	local items = parse_file()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "Edit Tools History",

			finder = finders.new_table({
				results = items,

				entry_maker = function(entry)
					local text = table.concat(entry.content or {}, " ")

					return {
						value = entry,

						-- ⭐ 只做展示，不做任何 highlight 逻辑
						display = string.format("[%s] %-5s %s", entry.time or "", entry.type or "", text),

						-- ⭐ 让 Telescope 负责 fuzzy search
						ordinal = (entry.type or "") .. " " .. text,
					}
				end,
			}),

			-- ⭐ Telescope 自己做排序 + 高亮
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

-- :History command
vim.api.nvim_create_user_command("History", function(opts)
	M.open(opts.args)
end, {
	nargs = "*",
})

return M
