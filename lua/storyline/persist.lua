local M = {}

local function state_dir()
  return vim.fn.stdpath("state") .. "/storyline"
end

--- キー = repo_root / mode / merge-base or topic / HEAD の合成。
local function key_for(story_data)
  local mode = story_data.mode or "pr"
  local scope = story_data.merge_base or story_data.topic or story_data.from_rev or ""
  return vim.fn.sha256(table.concat({
    story_data.repo_root or "",
    mode,
    tostring(scope),
    story_data.head_sha or "",
  }, ":"))
end

local function path_for(key)
  return state_dir() .. "/" .. key .. ".json"
end

--- read / opened / current_chapter のみを保存する（chapters 自体は保存しない）
function M.save(story_data)
  vim.fn.mkdir(state_dir(), "p")
  -- read は数値キーの疎なテーブルで JSON 化に向かないため id の配列にする
  local read_ids = {}
  for id in pairs(story_data.read) do
    table.insert(read_ids, id)
  end
  local tbl = {
    read_ids = read_ids,
    opened = story_data.opened,
    current_chapter = story_data.current_chapter,
  }
  local ok, encoded = pcall(vim.json.encode, tbl)
  if not ok then
    return
  end
  local file = io.open(path_for(key_for(story_data)), "w")
  if file then
    file:write(encoded)
    file:close()
  end
end

--- 同キーの保存があれば { read, opened, current_chapter } を返す。無い/壊れている場合は nil
function M.load(story_data)
  local file = io.open(path_for(key_for(story_data)), "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil
  end

  local read = {}
  for _, id in ipairs(decoded.read_ids or {}) do
    read[id] = true
  end

  return {
    read = read,
    opened = decoded.opened or {},
    current_chapter = decoded.current_chapter,
  }
end

return M
