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

--- AI 出力を検証・正規化する。信用できない出力は落とし、
--- AI が割り当て漏らしたファイルは「その他の変更」チャプターに合成する。
--- 有効なチャプターがひとつもなければ nil（呼び出し側でフォールバック）。
--- @param decoded any AI 出力を JSON デコードしたもの
--- @param files table 変更ファイル entries（git.changed_files の結果）
function M.validate(decoded, files)
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
