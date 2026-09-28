local M = {}

local function to_string_list(value)
  if type(value) ~= "table" then
    return {}
  end
  local out = {}
  for _, v in ipairs(value) do
    if type(v) == "string" and v ~= "" then
      table.insert(out, v)
    end
  end
  return out
end

--- テストを対象実装と同じチャプターへ移し、実装の直後に並べる（コロケーションの徹底）。
--- AI がテストを別チャプターに分けても、ここで機械的に直す。空になったチャプターは落とす。
local function colocate_tests(chapters)
  local trace = require("storyline.trace")

  local all_paths = {}
  local chapter_of = {}
  for _, ch in ipairs(chapters) do
    for _, path in ipairs(ch.files) do
      table.insert(all_paths, path)
      if not trace.is_test_path(path) then
        chapter_of[path] = ch
      end
    end
  end

  local moves = {}
  for _, ch in ipairs(chapters) do
    for _, path in ipairs(ch.files) do
      if trace.is_test_path(path) then
        local subject = trace.test_subject(path, all_paths)
        if subject and chapter_of[subject] then
          table.insert(moves, { test = path, subject = subject, from = ch, to = chapter_of[subject] })
        end
      end
    end
  end

  for _, mv in ipairs(moves) do
    for i, path in ipairs(mv.from.files) do
      if path == mv.test then
        table.remove(mv.from.files, i)
        break
      end
    end
    local anchor
    for i, path in ipairs(mv.to.files) do
      if path == mv.subject then
        anchor = i
        break
      end
    end
    if anchor then
      -- 実装の直後、すでに差し込んだテストの後ろへ
      local pos = anchor + 1
      while mv.to.files[pos] and trace.is_test_path(mv.to.files[pos]) do
        pos = pos + 1
      end
      table.insert(mv.to.files, pos, mv.test)
    else
      table.insert(mv.to.files, mv.test)
    end
  end

  local out = {}
  for _, ch in ipairs(chapters) do
    if #ch.files > 0 then
      ch.id = #out + 1
      table.insert(out, ch)
    end
  end
  return out
end

--- チャプター内のファイルを依存トレースの順（上流 → コア、テストは実装の直後）に並べ替える
local function apply_trace_order(chapters, trace_info)
  local rank = {}
  for i, path in ipairs(trace_info.paths or {}) do
    rank[path] = i
  end
  for _, ch in ipairs(chapters) do
    table.sort(ch.files, function(a, b)
      local ra, rb = rank[a] or math.huge, rank[b] or math.huge
      if ra ~= rb then
        return ra < rb
      end
      return a < b
    end)
  end
end

--- AI 出力を検証・正規化する。信用できない出力は落とし、
--- AI が割り当て漏らしたファイルは「その他の変更」チャプターに合成する。
--- 有効なチャプターがひとつもなければ nil（呼び出し側でフォールバック）。
--- テストのコロケーションとチャプター内の並び順は、AI の出力に関わらずここで徹底する。
--- @param decoded any AI 出力を JSON デコードしたもの
--- @param files table 変更ファイル entries（git.changed_files の結果）
--- @param opts? { leftover?: boolean, trace?: { paths?: string[] } }
---        leftover = false で「その他の変更」を合成しない
---        （読むモード用。PR レビューは全変更ファイルを見せる必要があるが、
---          読むモードでは AI が外したファイルを戻すと絞り込みが無意味になる）
---        trace は依存トレースの注釈。あればチャプター内をその順に並べ替える
function M.validate(decoded, files, opts)
  if type(decoded) ~= "table" or type(decoded.chapters) ~= "table" then
    return nil
  end

  local valid_paths = {}
  for _, f in ipairs(files) do
    valid_paths[f.path] = true
  end

  local assigned = {}
  local chapters = {}
  for _, ch in ipairs(decoded.chapters) do
    if type(ch) == "table" then
      local paths = {}
      for _, path in ipairs(to_string_list(ch.files)) do
        if valid_paths[path] and not assigned[path] then
          assigned[path] = true
          table.insert(paths, path)
        end
      end
      if #paths > 0 then
        table.insert(chapters, {
          id = #chapters + 1,
          title = type(ch.title) == "string" and ch.title or ("チャプター " .. (#chapters + 1)),
          summary = type(ch.summary) == "string" and ch.summary or "",
          review_points = to_string_list(ch.review_points),
          files = paths,
        })
      end
    end
  end

  if #chapters == 0 then
    return nil
  end

  if not (opts and opts.leftover == false) then
    local leftover = {}
    for _, f in ipairs(files) do
      if not assigned[f.path] then
        table.insert(leftover, f.path)
      end
    end
    if #leftover > 0 then
      table.insert(chapters, {
        id = #chapters + 1,
        title = "その他の変更",
        summary = "AI のグルーピングから漏れたファイルです。",
        review_points = {},
        files = leftover,
      })
    end
  end

  chapters = colocate_tests(chapters)
  if opts and opts.trace then
    apply_trace_order(chapters, opts.trace)
  end

  if #chapters == 0 then
    return nil
  end

  return {
    title = type(decoded.title) == "string" and decoded.title or "",
    chapters = chapters,
  }
end

--- 読むモード事前調査の JSON を正規化。無効なら nil。
function M.validate_scout(decoded)
  if type(decoded) ~= "table" then
    return nil
  end
  local summary = type(decoded.summary) == "string" and vim.trim(decoded.summary) or ""
  if summary == "" then
    return nil
  end

  local options = {}
  if type(decoded.options) == "table" then
    for _, opt in ipairs(decoded.options) do
      if type(opt) == "table" and type(opt.label) == "string" and vim.trim(opt.label) ~= "" then
        table.insert(options, {
          label = vim.trim(opt.label),
          keywords = to_string_list(opt.keywords),
        })
      end
    end
  end
  if #options == 0 then
    return nil
  end

  local question = type(decoded.question) == "string" and vim.trim(decoded.question) or ""
  if question == "" then
    question = "どれに興味がありますか？"
  end

  return {
    summary = summary,
    question = question,
    options = options,
  }
end

--- AI 不調時のフォールバック: トップレベルディレクトリ単位でグルーピング
function M.fallback(files)
  local groups, order = {}, {}
  for _, f in ipairs(files) do
    local dir = f.path:match("^([^/]+)/") or "(ルート)"
    if not groups[dir] then
      groups[dir] = {}
      table.insert(order, dir)
    end
    table.insert(groups[dir], f.path)
  end
  table.sort(order)

  local chapters = {}
  for _, dir in ipairs(order) do
    table.insert(chapters, {
      id = #chapters + 1,
      title = dir,
      summary = "ディレクトリ単位の自動グルーピングです（AI 解析なし）。",
      review_points = {},
      files = groups[dir],
    })
  end
  return { title = "", chapters = chapters }
end

return M
