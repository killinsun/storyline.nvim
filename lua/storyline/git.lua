local M = {}

--- git コマンドを同期実行して行配列を返す。失敗時は nil, err
local function run(args)
  local ok, proc = pcall(vim.system, args, { text = true })
  if not ok then
    return nil, "コマンドを実行できません: " .. args[1]
  end
  local result = proc:wait()
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "")
  end
  local out = vim.trim(result.stdout or "")
  if out == "" then
    return {}
  end
  return vim.split(out, "\n", { plain = true })
end

local function first_line(args)
  local lines = run(args)
  return lines and lines[1] or nil
end

function M.in_repo()
  return first_line({ "git", "rev-parse", "--is-inside-work-tree" }) == "true"
end

function M.repo_root()
  return first_line({ "git", "rev-parse", "--show-toplevel" })
end

function M.head_sha()
  return first_line({ "git", "rev-parse", "HEAD" })
end

--- base のデフォルト: gh の PR base → origin/HEAD → origin/main
function M.default_base()
  if vim.fn.executable("gh") == 1 then
    local base = first_line({ "gh", "pr", "view", "--json", "baseRefName", "-q", ".baseRefName" })
    if base and base ~= "" then
      return base
    end
  end
  local head = first_line({ "git", "symbolic-ref", "refs/remotes/origin/HEAD" })
  if head then
    return head:match("refs/remotes/(.+)$")
  end
  return "origin/main"
end

--- PR 比較ではリモート追跡 ref（origin/xxx）を優先する
function M.resolve_base_ref(base)
  if base:match("^origin/") or base:match("^remotes/") then
    return base
  end
  if first_line({ "git", "rev-parse", "--verify", "origin/" .. base }) then
    return "origin/" .. base
  end
  return base
end

function M.fetch_base(base)
  run({ "git", "fetch", "origin", (base:gsub("^origin/", "")), "--quiet" })
end

function M.merge_base(base)
  return first_line({ "git", "merge-base", base, "HEAD" })
end

function M.list_branches()
  local branches = run({ "git", "branch", "-a", "--format=%(refname:short)" }) or {}
  local seen, results = {}, {}
  for _, branch in ipairs(branches) do
    if branch ~= "" and branch ~= "HEAD" and not seen[branch] then
      seen[branch] = true
      table.insert(results, branch)
    end
  end
  table.sort(results)
  return results
end

function M.complete_branches()
  return M.list_branches()
end

--- numstat のパス表記（"dir/{old => new}" / "old => new"）を新パスへ正規化
local function normalize_rename(path)
  local prefix, old, new, suffix = path:match("^(.*){(.*) => (.*)}(.*)$")
  if prefix then
    local _ = old
    return (prefix .. new .. suffix):gsub("//", "/")
  end
  local from, to = path:match("^(.+) => (.+)$")
  if from then
    return to
  end
  return path
end

--- 変更ファイル一覧: { { path, status, added, deleted } }
--- status は git の1文字（A/M/D/R...）。merge-base vs 作業ツリー比較。
function M.changed_files(mb)
  local entries, by_path = {}, {}

  for _, line in ipairs(run({ "git", "diff", "--name-status", "-M", mb }) or {}) do
    local parts = vim.split(line, "\t", { plain = true })
    local status = (parts[1] or ""):sub(1, 1)
    -- rename は "R100 old new" 形式なので最後の列が新パス
    local path = parts[#parts]
    if path and path ~= "" then
      local entry = { path = path, status = status, added = 0, deleted = 0 }
      table.insert(entries, entry)
      by_path[path] = entry
    end
  end

  for _, line in ipairs(run({ "git", "diff", "--numstat", "-M", mb }) or {}) do
    local added, deleted, path = line:match("^(%S+)\t(%S+)\t(.+)$")
    if path then
      local entry = by_path[normalize_rename(path)]
      if entry then
        entry.added = tonumber(added) or 0 -- バイナリは "-" なので 0 扱い
        entry.deleted = tonumber(deleted) or 0
      end
    end
  end

  return entries
end

function M.diff_stat(mb)
  return table.concat(run({ "git", "diff", "--stat", mb }) or {}, "\n")
end

function M.full_diff_lines(mb)
  return run({ "git", "diff", "-M", mb }) or {}
end

function M.diff_hash(mb)
  return vim.fn.sha256(table.concat(M.full_diff_lines(mb), "\n"))
end

--- diff 全文を「1ファイルあたり max_lines 行まで」に丸める（テスト可能な純関数）
function M.truncate_diff(lines, max_lines)
  local out, count = {}, 0
  for _, line in ipairs(lines) do
    if line:match("^diff %-%-git ") then
      count = 0
      table.insert(out, line)
    elseif count < max_lines then
      count = count + 1
      table.insert(out, line)
      if count == max_lines then
        table.insert(out, "... (このファイルの diff は長いため省略)")
      end
    end
  end
  return out
end

function M.truncated_diff(mb, max_lines)
  return table.concat(M.truncate_diff(M.full_diff_lines(mb), max_lines), "\n")
end

--- 削除ファイル表示用: base 時点のファイル内容
function M.show_base_file(mb, path)
  return run({ "git", "show", mb .. ":" .. path })
end

local PR_BODY_MAX_CHARS = 2000

--- 現在のブランチに紐づく GitHub PR の title/body を取得する。gh が無い/PR が無いなら nil
function M.pr_info()
  if vim.fn.executable("gh") ~= 1 then
    return nil
  end
  local ok, proc = pcall(vim.system, { "gh", "pr", "view", "--json", "title,body" }, { text = true })
  if not ok then
    return nil
  end
  local result = proc:wait()
  if result.code ~= 0 then
    return nil
  end
  local decoded_ok, decoded = pcall(vim.json.decode, result.stdout or "")
  if not decoded_ok or type(decoded) ~= "table" then
    return nil
  end
  local body = decoded.body or ""
  return {
    title = decoded.title or "",
    body = body:sub(1, PR_BODY_MAX_CHARS),
  }
end

return M
