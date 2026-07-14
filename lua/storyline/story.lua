local M = {}

--- 現在のレビューセッション。nil なら未起動。
--- { repo_root, base_ref, merge_base, head_sha, title, chapters,
---   files_by_path, current_chapter, read = {}, opened = {}, collapsed = {} }
M.current = nil

function M.new(data)
  data.read = {}
  data.opened = {}
  data.collapsed = {}
  data.current_chapter = 1
  data.files_by_path = {}
  for _, f in ipairs(data.files) do
    data.files_by_path[f.path] = f
  end
  M.current = data
  return data
end

function M.clear()
  M.current = nil
end

function M.chapter(id)
  return M.current and M.current.chapters[id] or nil
end

function M.chapter_of(path)
  if not M.current then
    return nil
  end
  for _, ch in ipairs(M.current.chapters) do
    for _, p in ipairs(ch.files) do
      if p == path then
        return ch
      end
    end
  end
  return nil
end

--- ファイルを開いた記録。チャプター内全ファイルを開いたら自動読了。
--- 読了状態が変わったら true を返す（サイドバー再描画の要否）。
function M.mark_opened(path, auto_read)
  local story = M.current
  if not story or story.opened[path] then
    return false
  end
  story.opened[path] = true

  if not auto_read then
    return false
  end
  local ch = M.chapter_of(path)
  if not ch or story.read[ch.id] then
    return false
  end
  for _, p in ipairs(ch.files) do
    if not story.opened[p] then
      return false
    end
  end
  story.read[ch.id] = true
  return true
end

function M.toggle_read(id)
  local story = M.current
  if story then
    story.read[id] = not story.read[id] or nil
  end
end

return M
