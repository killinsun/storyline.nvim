local config = require("storyline.config")

local M = {}

function M.setup(opts)
  config.setup(opts)
end

--- from_rev 基準でコンテキストを集める
local function collect_from_rev(from_rev, compare)
  local git = require("storyline.git")
  if not git.in_repo() then
    vim.notify("Storyline: Git リポジトリ内ではありません", vim.log.levels.WARN)
    return nil
  end

  local files = git.changed_files(from_rev)
  if #files == 0 then
    local label = compare and compare.label or from_rev
    vim.notify("Storyline: " .. label .. " からの変更がありません", vim.log.levels.INFO)
    return nil
  end

  local paths = {}
  for _, f in ipairs(files) do
    table.insert(paths, f.path)
  end
  table.sort(paths)

  return {
    repo_root = git.repo_root(),
    base_ref = compare.base_ref or "",
    merge_base = from_rev, -- gitsigns / diff の比較元（from_rev）
    from_rev = from_rev,
    compare = compare,
    head_sha = git.head_sha() or "",
    files = files,
    stat = git.diff_stat(from_rev),
    diff = git.truncated_diff(from_rev, config.options.max_diff_lines_per_file),
    files_hash = vim.fn.sha256(table.concat(paths, "\n")),
    pr = git.pr_info(),
  }
end

--- PR base → merge-base コンテキスト
local function collect_pr(base_input)
  local git = require("storyline.git")
  local base = git.resolve_base_ref(base_input or git.default_base())
  git.fetch_base(base)

  local mb = git.merge_base(base)
  if not mb then
    vim.notify("Storyline: merge-base を取得できませんでした: " .. base, vim.log.levels.WARN)
    return nil
  end

  return collect_from_rev(mb, {
    mode = "pr",
    base_ref = base,
    from_sha = mb,
    label = base,
  })
end

--- コミット → HEAD コンテキスト
local function collect_commit(sha)
  local git = require("storyline.git")
  local short = git.short_sha(sha)
  return collect_from_rev(sha, {
    mode = "commit",
    base_ref = "",
    from_sha = sha,
    label = short,
  })
end

local function open_ui(ctx, result)
  local story = require("storyline.story")
  local layout = require("storyline.ui.layout")
  local sidebar = require("storyline.ui.sidebar")
  local main = require("storyline.ui.main")
  local summary = require("storyline.ui.summary")

  local keep_opened = nil
  if layout.is_open() and story.current then
    keep_opened = vim.deepcopy(story.current.opened or {})
    layout.close()
  end

  story.new({
    mode = ctx.mode or (ctx.compare and ctx.compare.mode) or "pr",
    topic = ctx.topic,
    repo_root = ctx.repo_root,
    base_ref = ctx.base_ref or "",
    merge_base = ctx.merge_base,
    from_rev = ctx.from_rev,
    compare = ctx.compare,
    head_sha = ctx.head_sha or "",
    files = ctx.files,
    title = result.title or "",
    chapters = result.chapters,
  })

  if keep_opened then
    story.current.opened = keep_opened
  end

  main.setup_session()
  layout.open()
  sidebar.attach(layout.sidebar_win)
  sidebar.render()

  local first = story.current.chapters[1]
  if first then
    local entry = story.current.files_by_path[first.files[1]]
    if entry then
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

local function run_analyze(ctx, opts)
  opts = opts or {}

  -- 変更ファイルに依存トレースを注釈する
  -- （プロンプトの依存関係セクション、テストのコロケーション、チャプター内の並び順に使う）
  local git = require("storyline.git")
  local trace = require("storyline.trace")
  local trace_paths = {}
  for _, f in ipairs(ctx.files) do
    table.insert(trace_paths, f.path)
  end
  ctx.trace = trace.annotate(trace_paths, function(path)
    return git.read_lines(path)
  end)

  local cache = require("storyline.cache")
  local key = cache.key({ ctx.repo_root, ctx.from_rev, ctx.head_sha, ctx.files_hash })

  if not opts.no_cache then
    local cached = cache.get(key)
    if cached and cached.chapters then
      local reconciled = require("storyline.ai.schema").validate(cached, ctx.files, { trace = ctx.trace })
      if reconciled then
        open_ui(ctx, reconciled)
        return
      end
    end
  end

  local ai = require("storyline.ai")
  local spinner = require("storyline.ui.spinner")
  spinner.start("Storyline: AI が変更を解析中..." .. ai.display_suffix())

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

--- opts:
---   base?: string
---   from_rev?: string
---   mode?: "pr"|"commit"
---   no_cache?: boolean
---   interactive?: boolean  -- 比較範囲を選ばせる
function M.start(opts)
  opts = opts or {}

  if opts.from_rev then
    local ctx = collect_commit(opts.from_rev)
    if ctx then
      run_analyze(ctx, opts)
    end
    return
  end

  if opts.base then
    local ctx = collect_pr(opts.base)
    if ctx then
      run_analyze(ctx, opts)
    end
    return
  end

  -- 引数なし / interactive: 比較範囲を選ぶ
  M.start_interactive(opts)
end

function M.start_interactive(opts)
  opts = opts or {}
  local pick = require("storyline.pick")
  pick.compare_mode(function(mode)
    if mode == "commit" then
      pick.commit(function(sha)
        local ctx = collect_commit(sha)
        if ctx then
          run_analyze(ctx, opts)
        end
      end)
    else
      pick.base_branch(function(base)
        local ctx = collect_pr(base)
        if ctx then
          run_analyze(ctx, opts)
        end
      end)
    end
  end)
end

function M.start_with_picker()
  M.start_interactive({})
end

--- キャッシュを無視して同じ比較範囲で再解析
function M.refresh()
  local story = require("storyline.story")
  local s = story.current
  if not s then
    M.start_interactive({ no_cache = true })
    return
  end
  if s.mode == "read" then
    M.start_read(s.topic or "")
    return
  end
  local compare = s.compare or { mode = "pr", base_ref = s.base_ref }
  if compare.mode == "commit" and (s.from_rev or compare.from_sha) then
    M.start({ from_rev = s.from_rev or compare.from_sha, no_cache = true })
  else
    M.start({ base = s.base_ref ~= "" and s.base_ref or nil, no_cache = true })
  end
end

--- 比較範囲を選び直して再起動（opened は open_ui 側で維持）
function M.change_compare()
  local story = require("storyline.story")
  if story.current and story.current.mode == "read" then
    M.start_read_interactive()
    return
  end
  M.start_interactive({ no_cache = true })
end

--- ユーザー指示に従ってチャプター構成を組み替える（セッション中のみ）
function M.reorganize(instruction)
  local story_mod = require("storyline.story")
  local s = story_mod.current
  if not s then
    vim.notify("Storyline: セッションがありません", vim.log.levels.WARN)
    return
  end
  instruction = vim.trim(instruction or "")
  if instruction == "" then
    return
  end

  local git = require("storyline.git")
  local from_rev = s.from_rev or s.merge_base
  local paths = {}
  for _, f in ipairs(s.files) do
    table.insert(paths, f.path)
  end
  table.sort(paths)

  local current_chapters = {}
  for _, ch in ipairs(s.chapters) do
    table.insert(current_chapters, { title = ch.title, files = ch.files })
  end

  local ctx = {
    files = s.files,
    stat = git.diff_stat(from_rev),
    diff = git.truncated_diff(from_rev, config.options.max_diff_lines_per_file),
    pr = git.pr_info(),
    instruction = instruction,
    current_chapters = current_chapters,
    -- 読むモードでは AI が外したファイルを「その他の変更」に戻さない
    leftover = s.mode ~= "read",
    -- 組み替えでも上流順とテストのコロケーションを徹底する
    trace = require("storyline.trace").annotate(paths, function(path)
      return git.read_lines(path)
    end),
  }

  local cache = require("storyline.cache")
  local key = cache.key({ s.repo_root, from_rev, s.head_sha, vim.fn.sha256(table.concat(paths, "\n")) })

  local ai = require("storyline.ai")
  local spinner = require("storyline.ui.spinner")
  local sidebar = require("storyline.ui.sidebar")
  local summary = require("storyline.ui.summary")
  local label = vim.fn.strcharpart(instruction, 0, 20) .. ai.display_suffix()
  spinner.start("Storyline 組み替え: " .. label)

  ai.analyze(ctx, function(result, err)
    spinner.stop()
    if not result then
      vim.notify("Storyline: 組み替えに失敗しました — " .. (err or ""), vim.log.levels.WARN)
      return
    end
    if not story_mod.apply_chapters(result.title, result.chapters) then
      vim.notify("Storyline: 組み替え結果を適用できませんでした", vim.log.levels.WARN)
      return
    end
    cache.put(key, result)
    sidebar.render()
    local first = story_mod.current and story_mod.current.chapters[1]
    if first and config.options.auto_summary then
      summary.show(first)
    end
    vim.notify("Storyline: ストーリーを組み替えました", vim.log.levels.INFO)
  end)
end

local function start_read_analyze(topic, paths, focus)
  local git = require("storyline.git")
  local trace = require("storyline.trace")

  -- 確定した候補に import 関係を注釈し、並びも「上流 → コア」に揃える
  local annotated = trace.annotate(paths, function(path)
    return git.read_lines(path)
  end)
  paths = annotated.paths

  local files = {}
  for _, path in ipairs(paths) do
    table.insert(files, { path = path, status = "M", added = 0, deleted = 0 })
  end

  local label_topic = topic
  if focus and focus ~= "" then
    label_topic = topic .. " / " .. focus
  end

  local ctx = {
    mode = "read",
    topic = topic,
    focus = focus,
    repo_root = git.repo_root(),
    base_ref = "",
    -- persist キー用。読むモードでは topic を scope にする
    merge_base = "read:" .. topic,
    from_rev = nil,
    compare = { mode = "read", label = label_topic },
    head_sha = git.head_sha() or "",
    files = files,
  }

  local ai = require("storyline.ai")
  local spinner = require("storyline.ui.spinner")
  local label = vim.fn.strcharpart(label_topic, 0, 28) .. ai.display_suffix()
  spinner.start("Storyline 読む: " .. label)

  ai.analyze_read({ topic = topic, focus = focus, files = files, trace = annotated }, function(result, err)
    spinner.stop()
    if not result then
      vim.notify("Storyline: 読むモードの解析に失敗しました — " .. (err or ""), vim.log.levels.WARN)
      return
    end
    open_ui(ctx, result)
  end)
end

local function preview_paths(paths, limit)
  limit = limit or 8
  local lines = {}
  for i = 1, math.min(limit, #paths) do
    table.insert(lines, "· " .. paths[i])
  end
  if #paths > limit then
    table.insert(lines, string.format("… 他 %d 件", #paths - limit))
  end
  return table.concat(lines, "\n")
end

local function format_scout_message(scout)
  local lines = { scout.summary, "" }
  for i, opt in ipairs(scout.options) do
    table.insert(lines, string.format("- %d. %s", i, opt.label))
  end
  table.insert(lines, "")
  table.insert(lines, scout.question)
  table.insert(
    lines,
    "番号かキーワードで答えてください。空 Enter / 「全部」でまとめて読みます。"
  )
  return table.concat(lines, "\n")
end

local function match_scout_option(instr, options)
  local n = tonumber(instr:match("^(%d+)"))
  if n and options[n] then
    return options[n]
  end
  local lower = instr:lower()
  for _, opt in ipairs(options) do
    if lower:find(opt.label:lower(), 1, true) then
      return opt
    end
  end
  return nil
end

local function filter_paths_by_option(paths, option)
  local keywords = vim.list_extend({}, option.keywords or {})
  if #keywords == 0 then
    for w in (option.label or ""):gmatch("[%w_]+") do
      if #w >= 3 then
        table.insert(keywords, w)
      end
    end
  end
  if #keywords == 0 then
    return paths
  end

  local out = {}
  for _, path in ipairs(paths) do
    local lower = path:lower()
    for _, kw in ipairs(keywords) do
      if lower:find(kw:lower(), 1, true) then
        table.insert(out, path)
        break
      end
    end
  end
  if #out == 0 then
    return paths
  end
  return out
end

local function refine_read_loop(topic, paths)
  local git = require("storyline.git")
  local chat = require("storyline.ui.read_chat")
  local ai = require("storyline.ai")
  local spinner = require("storyline.ui.spinner")

  local focus = nil
  local options = {}
  local busy = true

  local function confirm()
    chat.close()
    start_read_analyze(topic, paths, focus)
  end

  chat.open({
    topic = topic,
    on_cancel = function()
      spinner.stop()
      vim.notify("Storyline: 読むモードをキャンセルしました", vim.log.levels.INFO)
    end,
    on_submit = function(instr)
      if busy then
        return
      end
      instr = vim.trim(instr or "")
      if instr == "" or instr == "ok" or instr == "確定" or instr == "全部" then
        confirm()
        return
      end

      chat.append("user", instr)

      local opt = match_scout_option(instr, options)
      if opt then
        focus = opt.label
        -- キーワード一致に加え、import で繋がる上流・下流を残して読み筋を切らさない
        local matched = filter_paths_by_option(paths, opt)
        paths = git.chain_read_candidates(paths, matched)
        chat.append(
          "bot",
          string.format(
            "「%s」で進めます（import で繋がる上流・下流も残しています）。空 Enter で解析開始。追記でさらに絞り込みもできます（例: test 除外）。\n%s",
            opt.label,
            preview_paths(paths)
          )
        )
        return
      end

      -- 切り口の自由記述、または migration 除外などの絞り込み
      local looks_refine = instr:find("除外", 1, true)
        or instr:find("除く", 1, true)
        or instr:find("だけ", 1, true)
        or instr:find("のみ", 1, true)
        or instr:find("配下", 1, true)
        or instr:find("以下", 1, true)

      if looks_refine then
        local next_paths = git.refine_read_candidates(paths, instr)
        if #next_paths == 0 then
          chat.append(
            "bot",
            "0件になりました。別の指示を試すか、空 Enter で今の候補のまま確定できます。"
          )
          return
        end
        paths = next_paths
        chat.append(
          "bot",
          string.format("%d 件に絞り込みました。空 Enter で確定。\n%s", #paths, preview_paths(paths))
        )
        return
      end

      focus = instr
      chat.append(
        "bot",
        string.format(
          "「%s」に絞って読みます。空 Enter で解析開始。パス絞り込みも続けられます。",
          instr
        )
      )
    end,
  })

  chat.append("bot", "候補をざっと見て、切り口を整理しています…")
  spinner.start("Storyline 調査中…")

  local files = {}
  for _, path in ipairs(paths) do
    table.insert(files, { path = path })
  end

  ai.scout_read({ topic = topic, files = files }, function(scout, err)
    spinner.stop()
    busy = false
    if chat.closed then
      return
    end

    if not scout then
      chat.append(
        "bot",
        string.format(
          "調査に失敗したので、候補一覧から絞り込みましょう（%s）。\n空 Enter でこのまま解析。例: migration 除外 / graphql だけ\n\n%s",
          err or "不明なエラー",
          preview_paths(paths)
        )
      )
      return
    end

    options = scout.options
    chat.append("bot", format_scout_message(scout))
  end)
end

--- 読むモード: トピックに関連するコードをサイドバーにまとめてソース表示
function M.start_read(topic)
  topic = vim.trim(topic or "")
  if topic == "" then
    return
  end

  local git = require("storyline.git")
  if not git.in_repo() then
    vim.notify("Storyline: Git リポジトリ内ではありません", vim.log.levels.WARN)
    return
  end

  local paths = git.gather_read_candidates(topic, 150)
  if #paths == 0 then
    vim.notify(
      "Storyline: トピックに関連する候補ファイルが見つかりませんでした",
      vim.log.levels.WARN
    )
    return
  end

  refine_read_loop(topic, paths)
end

function M.start_read_interactive()
  vim.ui.input({ prompt = "Storyline 読むトピック: " }, function(topic)
    if topic and vim.trim(topic) ~= "" then
      M.start_read(topic)
    end
  end)
end

function M.toggle_layout()
  require("storyline.ui.main").toggle_layout()
end

function M.close()
  require("storyline.ui.summary").close()
  require("storyline.ui.layout").close()
end

return M
