local M = {}

local function get_file()
	return vim.fn.stdpath("data") .. "/edit-tools/history.jsonl"
end

local function parse_file()
	local file = io.open(get_file(), "r")
	if not file then
		return {}
	end

	local items = {}

	for line in file:lines() do
		local ok, obj = pcall(vim.json.decode, line)
		if ok and obj then
			local text = table.concat(obj.content or {}, " ")

			table.insert(items, {
				time = obj.time,
				type = obj.type,
				text = text,
				raw = obj,
			})
		end
	end

	file:close()
	return items
end

function M.open()
	local ok, telescope = pcall(require, "telescope")
	if not ok then
		vim.notify("Telescope not found", vim.log.levels.ERROR)
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local items = parse_file()

	pickers
		.new({}, {
			prompt_title = "Edit Tools History",
			finder = finders.new_table({
				results = items,
				entry_maker = function(entry)
					local preview = entry.text:gsub("\n", " ")
					if #preview > 80 then
						preview = preview:sub(1, 80) .. "..."
					end

					return {
						value = entry,
						display = string.format("[%s] %-6s %s", entry.time, entry.type, preview),
						ordinal = entry.text,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				local function paste_selection()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)

					if not selection then
						return
					end

					local lines = vim.split(selection.value.text, "\n")

					vim.api.nvim_put(lines, "c", true, true)
				end

				map("i", "<CR>", paste_selection)
				map("n", "<CR>", paste_selection)

				return true
			end,
		})
		:find()
end

function M.setup()
	vim.keymap.set("n", "<leader>kh", M.open, {
		desc = "Open history (Telescope)",
	})
end

return M
