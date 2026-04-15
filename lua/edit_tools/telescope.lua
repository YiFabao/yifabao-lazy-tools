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
						value = entry,

						-- 🔥 search engine core (NO custom logic)
						ordinal = table.concat({
							entry.type or "",
							entry.time or "",
							entry.text or "",
						}, " "),

						-- Add display_name for better preview handling
						display_name = entry.time .. " [" .. (entry.type or "") .. "] " .. preview,

						-- =========================
						-- UI rendering only
						-- =========================
						display = function()
							return displayer({
								entry.time or "",
								entry.type or "",
								preview,
							})
						end,
					}
				end,
			}),

			-- =========================
			-- fuzzy sorter (Telescope default engine) with highlights
			-- =========================
			sorter = conf.generic_sorter({}),

			-- =========================
			-- Custom previewer that shows the full content
			-- =========================
			previewer = (function()
				local builtin_previewer = require("telescope.previewers").builtin
				return builtin_previewer.new({
					title = "Full Content",
					-- Define how to show the preview
					define_preview = function(self, entry, status)
						if not entry or not entry.value then
							vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "" })
							return
						end

						local content = entry.value.text or ""
						local lines = vim.split(content, "\n")

						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
						vim.api.nvim_buf_set_option(self.state.bufnr, "filetype", "markdown") -- Set appropriate filetype
						vim.api.nvim_buf_set_option(self.state.bufnr, "buftype", "nofile")
					end,
				})
			end)(),

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
