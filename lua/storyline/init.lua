local config = require("storyline.config")

local M = {}

function M.setup(opts)
  config.setup(opts)
end

--- レビュー対象の情報を集める。続行できない場合は通知して nil
local function collect_context(base_input)
  local git = require("storyline.git")
  if not git.in_repo() then
    vim.notify("Storyline: Git リポジトリ内ではありません", vim.log.levels.WARN)
    return nil
  end

  local base = git.resolve_base_ref(base_input or git.default_base())
  git.fetch_base(base)

  local mb = git.merge_base(base)
  if not mb then
    vim.notify("Storyline: merge-base を取得できませんでした: " .. base, vim.log.levels.WARN)
    return nil
  end

  local files = git.changed_files(mb)
  if #files == 0 then
    vim.notify("Storyline: " .. base .. " からの変更がありません", vim.log.levels.INFO)
    return nil
  end

  -- キャッシュキーは「変更ファイルの集合」に基づく。diff 全文をキーにすると
  -- レビュー中の1行の編集でも毎回 AI 再解析になってしまうため、
  -- ファイル集合が同じならチャプター構成を再利用する（内容は R で再解析可能）。
  local paths = {}
  for _, f in ipairs(files) do
    table.insert(paths, f.path)
  end
  table.sort(paths)

  return {
    repo_root = git.repo_root(),
    base_ref = base,
    merge_base = mb,
    head_sha = git.head_sha() or "",
    files = files,
    stat = git.diff_stat(mb),
    diff = git.truncated_diff(mb, config.options.max_diff_lines_per_file),
    files_hash = vim.fn.sha256(table.concat(paths, "\n")),
    pr = git.pr_info(),
  }
end

local function open_ui(ctx, result)
  local story = require("storyline.story")
  local layout = require("storyline.ui.layout")
  local sidebar = require("storyline.ui.sidebar")
  local main = require("storyline.ui.main")
  local summary = require("storyline.ui.summary")

  if layout.is_open() then
    layout.close()
  end

  story.new({
    repo_root = ctx.repo_root,
    base_ref = ctx.base_ref,
    merge_base = ctx.merge_base,
    head_sha = ctx.head_sha,
    files = ctx.files,
    title = result.title or "",
    chapters = result.chapters,
  })

  main.setup_session()
  layout.open()
  sidebar.attach(layout.sidebar_win)
  sidebar.render()

  local first = story.current.chapters[1]
  if first then
    local entry = story.current.files_by_path[first.files[1]]
    if entry then
      -- gitsigns のレイアウト適用は非同期なので、フォーカス復帰と概要表示は完了後に行う
      main.open_file(entry, {
        keep_focus = "sidebar",
        on_done = function()
          if config.options.auto_summary then
            summary.show(first)
          end
        end,
      })
    else
      layout.focus_sidebar()
      if config.options.auto_summary then
        summary.show(first)
      end
    end
  else
    layout.focus_sidebar()
  end
end

--- opts: { base?: string, no_cache?: boolean }
function M.start(opts)
  opts = opts or {}
  local ctx = collect_context(opts.base)
  if not ctx then
    return
  end

  local cache = require("storyline.cache")
  local key = cache.key({ ctx.repo_root, ctx.merge_base, ctx.head_sha, ctx.files_hash })

  if not opts.no_cache then
    local cached = cache.get(key)
    if cached and cached.chapters then
      -- 現在のファイル集合と突き合わせて正規化（stale なパスの除去・追加分の救済）
      local reconciled = require("storyline.ai.schema").validate(cached, ctx.files)
      if reconciled then
        open_ui(ctx, reconciled)
        return
      end
    end
  end

  local ai = require("storyline.ai")
  local spinner = require("storyline.ui.spinner")
  local backend = ai.resolve_backend()
  spinner.start("Storyline: AI が変更を解析中..." .. (backend and (" (" .. backend.name .. ")") or ""))

  ai.analyze(ctx, function(result, err)
    spinner.stop()
    if result then
      cache.put(key, result)
      open_ui(ctx, result)
    else
      vim.notify(
        "Storyline: AI 解析に失敗したためディレクトリ単位で表示します — " .. (err or ""),
        vim.log.levels.WARN
      )
      open_ui(ctx, ai.fallback(ctx.files))
    end
  end)
end

function M.start_with_picker()
  local git = require("storyline.git")
  if not git.in_repo() then
    vim.notify("Storyline: Git リポジトリ内ではありません", vim.log.levels.WARN)
    return
  end
  local branches = git.list_branches()
  if #branches == 0 then
    vim.notify("Storyline: ブランチ一覧を取得できませんでした", vim.log.levels.WARN)
    return
  end
  vim.ui.select(branches, { prompt = "Storyline: 比較元ブランチ" }, function(choice)
    if choice then
      M.start({ base = choice })
    end
  end)
end

--- キャッシュを無視して AI 解析をやり直す
function M.refresh()
  local story = require("storyline.story")
  local base = story.current and story.current.base_ref or nil
  M.start({ base = base, no_cache = true })
end

function M.toggle_layout()
  require("storyline.ui.main").toggle_layout()
end

function M.close()
  require("storyline.ui.summary").close()
  require("storyline.ui.layout").close()
end

return M
