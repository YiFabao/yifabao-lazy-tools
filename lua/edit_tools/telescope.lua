local M = {}

function M.open()
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local file = io.open(vim.fn.stdpath("data") .. "/edit-tools/history.jsonl", "r")
	if not file then
		return
	end

	local items = {}

	for line in file:lines() do
		local ok, obj = pcall(vim.json.decode, line)
		if ok then
			table.insert(items, obj)
		end
	end

	file:close()

	pickers
		.new({}, {
			prompt_title = "History",

			finder = finders.new_table({
				results = items,
				entry_maker = function(e)
					local text = table.concat(e.content or {}, " ")

					return {
						value = e,
						display = string.format("[%s] %s", e.type, text),
						ordinal = text,
					}
				end,
			}),

			sorter = conf.generic_sorter({}),

			attach_mappings = function(bufnr, map)
				map("i", "<CR>", function()
					local sel = action_state.get_selected_entry()
					actions.close(bufnr)

					vim.fn.setreg("+", table.concat(sel.value.content, "\n"))
				end)

				return true
			end,
		})
		:find()
end

return M
