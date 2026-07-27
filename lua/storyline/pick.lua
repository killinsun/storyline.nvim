local config = require("storyline.config")
local git = require("storyline.git")

local M = {}

local function move_default_first(items, default)
  if not default then
    return items
  end
  local out, found = {}, false
  for _, item in ipairs(items) do
    if item == default then
      found = true
    else
      table.insert(out, item)
    end
  end
  if found then
    table.insert(out, 1, default)
  end
  return out
end

--- 比較モード: cb("pr"|"commit")
function M.compare_mode(cb)
  local items = {
    { id = "pr", label = "PR base から（merge-base → 作業ツリー）" },
    { id = "commit", label = "コミットから HEAD（レビュー後の差分など）" },
  }
  local ok = pcall(require, "telescope.pickers")
  if ok then
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    pickers
      .new({}, {
        prompt_title = "Storyline: 比較範囲",
        finder = finders.new_table({
          results = items,
          entry_maker = function(e)
            return { value = e.id, display = e.label, ordinal = e.label }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
          local function select()
            local entry = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if entry then
              cb(entry.value)
            end
          end
          actions.select_default:replace(select)
          map("i", "<CR>", select)
          map("n", "<CR>", select)
          return true
        end,
      })
      :find()
    return
  end

  vim.ui.select(items, {
    prompt = "Storyline: 比較範囲",
    format_item = function(e)
      return e.label
    end,
  }, function(choice)
    if choice then
      cb(choice.id)
    end
  end)
end

--- base ブランチ選択（opts.pick_base または内蔵）
function M.base_branch(cb)
  if type(config.options.pick_base) == "function" then
    config.options.pick_base(cb)
    return
  end

  local branches = git.list_branches()
  if #branches == 0 then
    vim.notify("Storyline: ブランチ一覧を取得できませんでした", vim.log.levels.WARN)
    return
  end

  local default = git.default_base()
  if default then
    default = git.resolve_base_ref(default)
  end
  branches = move_default_first(branches, default)

  local ok = pcall(require, "telescope.pickers")
  if ok then
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local title = "Storyline: 比較元ブランチ"
    if default then
      title = title .. " (" .. default .. ")"
    end
    pickers
      .new({}, {
        prompt_title = title,
        finder = finders.new_table({ results = branches }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
          local function select()
            local entry = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if entry then
              cb(entry[1] or entry.value)
            end
          end
          actions.select_default:replace(select)
          map("i", "<CR>", select)
          map("n", "<CR>", select)
          return true
        end,
      })
      :find()
    return
  end

  vim.ui.select(branches, { prompt = "Storyline: 比較元ブランチ" }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

--- コミット選択: cb(sha)
function M.commit(cb)
  local commits = git.list_commits(80)
  if #commits == 0 then
    vim.notify("Storyline: コミット一覧を取得できませんでした", vim.log.levels.WARN)
    return
  end

  local ok = pcall(require, "telescope.pickers")
  if ok then
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local entry_display = require("telescope.pickers.entry_display")
    local displayer = entry_display.create({
      separator = "  ",
      items = {
        { width = 7 },
        { width = 11 },
        { width = 6 },
        { remaining = true },
      },
    })
    pickers
      .new({}, {
        prompt_title = "Storyline: 比較元コミット → HEAD",
        finder = finders.new_table({
          results = commits,
          entry_maker = function(c)
            local label = git.format_commit_display(c)
            return {
              value = c.sha,
              ordinal = label,
              display = function()
                return displayer({
                  { c.short },
                  { c.when_jst or "" },
                  { c.pr and ("#" .. c.pr) or "" },
                  { c.subject or "" },
                })
              end,
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
          local function select()
            local entry = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if entry then
              cb(entry.value)
            end
          end
          actions.select_default:replace(select)
          map("i", "<CR>", select)
          map("n", "<CR>", select)
          return true
        end,
      })
      :find()
    return
  end

  vim.ui.select(commits, {
    prompt = "Storyline: 比較元コミット → HEAD",
    format_item = function(c)
      return git.format_commit_display(c)
    end,
  }, function(choice)
    if choice then
      cb(choice.sha)
    end
  end)
end

return M
