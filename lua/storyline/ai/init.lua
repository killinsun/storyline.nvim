local config = require("storyline.config")
local prompt = require("storyline.ai.prompt")
local schema = require("storyline.ai.schema")

local M = {}

local backends = {
  claude = require("storyline.ai.backends.claude"),
  codex = require("storyline.ai.backends.codex"),
  cursor = require("storyline.ai.backends.cursor"),
}

local ORDER = { "claude", "codex", "cursor" }

local function backend_cfg(name)
  return config.options.backends[name]
end

function M.resolve_backend()
  local want = config.options.backend
  if want ~= "auto" then
    local backend = backends[want]
    if backend and backend.available(backend_cfg(want)) then
      return backend
    end
    return nil
  end
  for _, name in ipairs(ORDER) do
    if backends[name].available(backend_cfg(name)) then
      return backends[name]
    end
  end
  return nil
end

function M.pick_backend()
  local items = {}
  for _, name in ipairs(ORDER) do
    if backends[name].available(backend_cfg(name)) then
      table.insert(items, name)
    end
  end
  if #items == 0 then
    vim.notify("Storyline: 利用可能な AI バックエンドがありません", vim.log.levels.WARN)
    return
  end
  vim.ui.select(items, {
    prompt = "Storyline AI バックエンド",
    format_item = function(name)
      local mark = name == config.options.backend and " (現在)" or ""
      return backends[name].label .. mark
    end,
  }, function(choice)
    if choice then
      config.options.backend = choice
      vim.notify("Storyline: バックエンド = " .. choice, vim.log.levels.INFO)
    end
  end)
end

--- 出力テキストから JSON オブジェクトを取り出してデコード
local function extract_json(text)
  if not text then
    return nil
  end
  text = text:gsub("```%w*", "")
  local first = text:find("{", 1, true)
  local last = text:reverse():find("}", 1, true)
  if not first or not last then
    return nil
  end
  local candidate = text:sub(first, #text - last + 1)
  local ok, decoded = pcall(vim.json.decode, candidate)
  if ok then
    return decoded
  end
  return nil
end

--- diff を AI で解析してチャプター構成を作る（完全非同期）
--- cb(story, err) はメインループで呼ばれる。story == nil ならエラー。
function M.analyze(ctx, cb)
  local backend = M.resolve_backend()
  if not backend then
    cb(nil, "利用可能な AI バックエンドがありません（backend = " .. config.options.backend .. "）")
    return
  end

  local cfg = backend_cfg(backend.name)
  local payload = prompt.build(ctx)

  local function attempt(input, on_fail)
    local ok, proc = pcall(vim.system, backend.build_cmd(cfg), {
      text = true,
      stdin = input,
      timeout = config.options.timeout_ms,
    }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          local err = vim.trim(result.stderr or "")
          on_fail(backend.name .. " が異常終了しました (code=" .. result.code .. ") " .. err:sub(1, 200))
          return
        end
        local story = schema.validate(extract_json(result.stdout), ctx.files)
        if story then
          cb(story)
        else
          on_fail(backend.name .. " の出力を JSON として解釈できませんでした")
        end
      end)
    end)
    if not ok then
      vim.schedule(function()
        on_fail("コマンドを実行できません: " .. cfg.cmd)
      end)
    end
  end

  attempt(payload, function()
    -- 1回だけ「JSON のみで再出力」を指示してリトライ
    attempt(payload .. prompt.retry_suffix, function(err)
      cb(nil, err)
    end)
  end)
end

--- チャプターについての質問に自由テキストで回答させる（完全非同期、リトライなし）
--- payload はそのまま stdin に渡すプロンプト文字列。cb(answer, err) はメインループで呼ばれる。answer == nil ならエラー。
function M.ask(payload, cb)
  local backend = M.resolve_backend()
  if not backend then
    cb(nil, "利用可能な AI バックエンドがありません（backend = " .. config.options.backend .. "）")
    return
  end

  local cfg = backend_cfg(backend.name)
  local ok = pcall(vim.system, backend.build_cmd(cfg), {
    text = true,
    stdin = payload,
    timeout = config.options.timeout_ms,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local err = vim.trim(result.stderr or "")
        cb(nil, backend.name .. " が異常終了しました (code=" .. result.code .. ") " .. err:sub(1, 200))
        return
      end
      cb(vim.trim(result.stdout or ""))
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(nil, "コマンドを実行できません: " .. cfg.cmd)
    end)
  end
end

M.fallback = schema.fallback

return M
