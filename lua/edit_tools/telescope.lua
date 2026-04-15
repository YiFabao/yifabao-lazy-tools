local M = {}

local function get_file()
	return vim.fn.stdpath("data") .. "/edit-tools/knowledge.jsonl"
end

-- =========================
-- parse jsonl knowledge base
-- =========================
local function parse_file()
	local file = io.open(get_file(), "r")
	if not file then
		return {}
	end

	local items = {}

	for line in file:lines() do
		local ok, obj = pcall(vim.json.decode, line)
		if ok and obj then
			local text = type(obj.content) == "table" and table.concat(obj.content, " ") or (obj.content or "")

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

-- =========================
-- setup telescope UI
-- =========================
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

	local EntryDisplay = require("telescope.pickers.entry_display")

	local items = parse_file()

	-- =========================
	-- structured UI layout
	-- =========================
	local displayer = EntryDisplay.create({
		separator = " ",
		items = {
			{ width = 19 }, -- time
			{ width = 8 }, -- type
			{ remaining = true },
		},
	})

	pickers
		.new({}, {
			prompt_title = "Knowledge Base",

			-- =========================
			-- search source (IMPORTANT)
			-- Telescope handles fuzzy + highlight
			-- =========================
			finder = finders.new_table({
				results = items,

				entry_maker = function(entry)
					local preview = entry.text:gsub("\n", " ")

					if #preview > 120 then
						preview = preview:sub(1, 120) .. "..."
					end

					return {
						-- Store all data in value
						value = entry,
						-- For searching
						ordinal = table.concat({
							entry.time or "",
							entry.type or "",
							entry.text or "",
						}, " "),
						-- For display
						display = function()
							return displayer({
								entry.time or "",
								entry.type or "",
								preview,
							})
						end,
						-- Make sure the entry has all necessary fields for preview
						filename = vim.fn.tempname() .. (entry.type and "." .. entry.type or ".txt"),
						cwd = vim.loop.cwd(),
					}
				end,
			}),

			-- =========================
			-- fuzzy sorter (Telescope default engine) with highlights
			-- =========================
			sorter = conf.generic_sorter({}),

			-- =========================
			-- Disable default previewer and use a simple one
			-- =========================
			previewer = require("telescope.previewers").new_buffer_previewer({
				title = "Knowledge Content",
				define_preview = function(self, entry, status)
					if not self.state.bufnr then
						return
					end

					-- Safety check for entry and its value
					local content = "No content available"
					if entry and entry.value and entry.value.text then
						content = entry.value.text
					elseif entry and entry.value then
						-- If text is missing but we have other data, show it
						content = vim.inspect(entry.value)
					end

					local lines = vim.split(content, "\n")
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.api.nvim_buf_set_option(self.state.bufnr, "filetype", "markdown")
					vim.api.nvim_buf_set_option(self.state.bufnr, "buftype", "nofile")
					vim.api.nvim_buf_set_option(self.state.bufnr, "bufhidden", "hide")
				end,
			}),

			-- =========================
			-- actions
			-- =========================
			attach_mappings = function(prompt_bufnr, map)
				-- insert into buffer (knowledge reuse)
				local function insert_entry()
					local selection = action_state.get_selected_entry()
					if not selection then
						return
					end

					actions.close(prompt_bufnr)

					local text = selection.value.text
					vim.api.nvim_put(vim.split(text, "\n"), "c", true, true)
				end

				-- yank to clipboard
				local function yank_entry()
					local selection = action_state.get_selected_entry()
					if not selection then
						return
					end

					vim.fn.setreg("+", selection.value.text)
					vim.notify("Knowledge copied")
				end

				map("i", "<CR>", insert_entry)
				map("n", "<CR>", insert_entry)

				map("i", "yy", yank_entry)
				map("n", "yy", yank_entry)

				return true
			end,
		})
		:find()
end

-- =========================
-- keymap
-- =========================
function M.setup()
	vim.keymap.set("n", "<leader>ik", M.open, {
		desc = "Open knowledge base (Telescope)",
	})
end

return M
