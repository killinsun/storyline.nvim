local M = {}

local function cache_dir()
  return vim.fn.stdpath("cache") .. "/storyline"
end

--- キー = repo_root / merge-base / HEAD / 作業ツリー diff ハッシュ の合成
function M.key(parts)
  return vim.fn.sha256(table.concat(parts, ":"))
end

local function path_for(key)
  return cache_dir() .. "/" .. key .. ".json"
end

function M.get(key)
  local file = io.open(path_for(key), "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, content)
  return ok and decoded or nil
end

function M.put(key, tbl)
  vim.fn.mkdir(cache_dir(), "p")
  local ok, encoded = pcall(vim.json.encode, tbl)
  if not ok then
    return
  end
  local file = io.open(path_for(key), "w")
  if file then
    file:write(encoded)
    file:close()
  end
end

return M
