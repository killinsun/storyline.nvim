local persist = require("storyline.persist")

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

  -- 同一 HEAD での前回セッションがあれば読了/既読/カレントチャプターを復元する
  local saved = persist.load(data)
  if saved then
    data.read = saved.read
    data.opened = saved.opened
    if saved.current_chapter and data.chapters[saved.current_chapter] then
      data.current_chapter = saved.current_chapter
    end
  end

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

  local read_changed = false
  if auto_read then
    local ch = M.chapter_of(path)
    if ch and not story.read[ch.id] then
      local all_opened = true
      for _, p in ipairs(ch.files) do
        if not story.opened[p] then
          all_opened = false
          break
        end
      end
      if all_opened then
        story.read[ch.id] = true
        read_changed = true
      end
    end
  end

  persist.save(story)
  return read_changed
end

function M.toggle_read(id)
  local story = M.current
  if story then
    story.read[id] = not story.read[id] or nil
    persist.save(story)
  end
end

--- ファイルの読了チェックをトグルする。状態が変わったら true
function M.toggle_opened(path)
  local story = M.current
  if not story or not path then
    return false
  end
  if story.opened[path] then
    story.opened[path] = nil
  else
    story.opened[path] = true
  end
  persist.save(story)
  return true
end

--- AI 組み替え後にチャプター構成だけ差し替える。
--- opened（パス単位）は維持し、read / collapsed / current_chapter はリセットする。
function M.apply_chapters(title, chapters)
  local story = M.current
  if not story or type(chapters) ~= "table" or #chapters == 0 then
    return false
  end
  story.title = title or story.title or ""
  story.chapters = chapters
  story.read = {}
  story.collapsed = {}
  story.current_chapter = 1
  persist.save(story)
  return true
end

--- サイドバーからカレントチャプターを切り替えた際に呼ぶ
function M.set_current_chapter(id)
  local story = M.current
  if story then
    story.current_chapter = id
    persist.save(story)
  end
end

return M
