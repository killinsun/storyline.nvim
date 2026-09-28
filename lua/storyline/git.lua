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

--- ISO8601（%cI）を JST の MM/DD HH:mm にする
function M.format_jst(iso)
  if not iso or iso == "" then
    return "??/?? ??:??"
  end
  local y, mo, d, h, mi, s = iso:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return "??/?? ??:??"
  end
  y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s) or 0

  local offset_sec = 0
  if not iso:match("Z$") then
    local sign, oh, om = iso:match("([+-])(%d%d):?(%d%d)$")
    if sign then
      offset_sec = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
    end
  end

  -- os.time はローカル解釈。UTC epoch = local解釈 + local_tz - 記載オフセット
  local as_local = os.time({
    year = y,
    month = mo,
    day = d,
    hour = h,
    min = mi,
    sec = s,
    isdst = false,
  })
  if not as_local then
    return string.format("%02d/%02d %02d:%02d", mo, d, h, mi)
  end
  local now = os.time()
  local local_tz = os.difftime(now, os.time(os.date("!*t", now)))
  local utc_epoch = as_local + local_tz - offset_sec
  local jst = os.date("!*t", utc_epoch + 9 * 3600)
  return string.format("%02d/%02d %02d:%02d", jst.month, jst.day, jst.hour, jst.min)
end

--- 表示用: `988c661  07/16 06:12  #128  subject`
function M.format_commit_display(c)
  local pr_col = c.pr and ("#" .. tostring(c.pr)) or ""
  return string.format("%s  %s  %-6s%s", c.short or "", c.when_jst or "??/?? ??:??", pr_col, c.subject or "")
end

--- gh で最近の PR を取り、commit sha → PR number のマップを作る（失敗時は空）
local function pr_number_by_sha()
  if vim.fn.executable("gh") == 0 then
    return {}
  end
  local ok, proc = pcall(vim.system, {
    "gh",
    "pr",
    "list",
    "--state",
    "all",
    "--limit",
    "40",
    "--json",
    "number,commits,mergeCommit",
  }, { text = true })
  if not ok then
    return {}
  end
  local result = proc:wait()
  if result.code ~= 0 then
    return {}
  end
  local decoded_ok, data = pcall(vim.json.decode, result.stdout or "")
  if not decoded_ok or type(data) ~= "table" then
    return {}
  end

  local map = {}
  for _, pr in ipairs(data) do
    local num = pr.number
    if type(num) == "number" then
      if type(pr.mergeCommit) == "table" and type(pr.mergeCommit.oid) == "string" then
        map[pr.mergeCommit.oid] = num
      end
      if type(pr.commits) == "table" then
        for _, c in ipairs(pr.commits) do
          if type(c) == "table" and type(c.oid) == "string" then
            map[c.oid] = num
          end
        end
      end
    end
  end
  return map
end

--- 最近のコミット一覧: { { sha, short, subject, when_jst, pr? } }
function M.list_commits(limit)
  limit = limit or 50
  local lines = run({
    "git",
    "log",
    "-n",
    tostring(limit),
    "--format=%H\t%h\t%cI\t%s",
  }) or {}
  local commits = {}
  for _, line in ipairs(lines) do
    local sha, short, iso, subject = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
    if sha then
      table.insert(commits, {
        sha = sha,
        short = short,
        subject = subject or "",
        when_jst = M.format_jst(iso),
      })
    end
  end

  local pr_map = pr_number_by_sha()
  for _, c in ipairs(commits) do
    c.pr = pr_map[c.sha]
    if not c.pr then
      local n = c.subject:match("%(#(%d+)%)") or c.subject:match("Merge pull request #(%d+)")
      if n then
        c.pr = tonumber(n)
      end
    end
  end

  return commits
end

--- from_rev を短縮表示用に
function M.short_sha(rev)
  if not rev then
    return ""
  end
  local short = first_line({ "git", "rev-parse", "--short", rev })
  return short or rev:sub(1, 7)
end

--- トピックから検索トークンを抜く（日本語文でも ASCII 識別子を拾う）
local function read_tokens(topic)
  local tokens, seen = {}, {}
  local function add_tok(t)
    if not t or t == "" or seen[t] then
      return
    end
    -- 1文字だけのノイズは除外（日本語助詞など）
    if vim.fn.strchars(t) < 2 then
      return
    end
    seen[t] = true
    table.insert(tokens, t)
  end

  for tok in (topic or ""):gmatch("%S+") do
    add_tok(tok)
  end
  -- CamelCase / snake_case / 英数字かたまり
  for tok in (topic or ""):gmatch("[%w_]+") do
    if #tok >= 2 and not tok:match("^%d+$") then
      add_tok(tok)
    end
  end
  return tokens
end

local RG_GLOBS = {
  "!**/node_modules/**",
  "!**/.git/**",
  "!**/dist/**",
  "!**/build/**",
  "!**/coverage/**",
  "!**/migrations/**",
  "!**/prisma/migrations/**",
  "!**/*migration*.sql",
  "!**/*.lock",
  "!**/package-lock.json",
  "!**/yarn.lock",
  "!**/pnpm-lock.yaml",
}

--- 読むモードの候補から外すノイズ（migration / lock / 生成物など）
local function is_read_noise(path)
  local lower = path:lower()
  if lower:match("/migrations?/") or lower:match("^migrations?/") then
    return true
  end
  if lower:match("migration.*%.sql$") or lower:match("%.sql$") and lower:find("migrat", 1, true) then
    return true
  end
  if
    lower:match("%.lock$")
    or lower:match("package%-lock%.json$")
    or lower:match("yarn%.lock$")
    or lower:match("pnpm%-lock%.yaml$")
  then
    return true
  end
  if lower:match("%.min%.[jt]s$") or lower:match("%.map$") or lower:match("%.snap$") then
    return true
  end
  if lower:find("/generated/", 1, true) or lower:find("/.next/", 1, true) then
    return true
  end
  return false
end

--- import 抽出用にファイル先頭を読む
local READ_LINES_CAP = 800

function M.read_lines(path, cap)
  local root = M.repo_root()
  if not root then
    return nil
  end
  local full = root .. "/" .. path
  if vim.fn.filereadable(full) ~= 1 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, full, "", cap or READ_LINES_CAP)
  if not ok then
    return nil
  end
  return lines
end

--- keys のいずれかを含むファイルを repo 全体から探す（逆参照＝import している側の候補）
local function search_refs(root, keys)
  if vim.fn.executable("rg") ~= 1 or #keys == 0 then
    return {}
  end
  local args = { "rg", "-l", "-i", "-F" }
  for i, key in ipairs(keys) do
    if i > 20 then
      break
    end
    table.insert(args, "-e")
    table.insert(args, key)
  end
  for _, g in ipairs(RG_GLOBS) do
    table.insert(args, "--glob")
    table.insert(args, g)
  end
  local ok, proc = pcall(vim.system, args, { cwd = root, text = true })
  if not ok then
    return {}
  end
  local result = proc:wait()
  if result.code ~= 0 and result.code ~= 1 then
    return {}
  end
  local out = {}
  for _, line in ipairs(vim.split(result.stdout or "", "\n", { plain = true })) do
    if line ~= "" then
      table.insert(out, line)
    end
    if #out >= 120 then
      break
    end
  end
  return out
end

--- 本文一致の候補を rg で集める（seed 以外の弱い候補）
local function content_matches(root, tokens, skip, max_files)
  if vim.fn.executable("rg") ~= 1 then
    return {}
  end
  local seen, paths = {}, {}
  for _, tok in ipairs(tokens) do
    if #paths >= max_files then
      break
    end
    -- 短すぎる / 日本語だけの長い文全体は rg のノイズになりやすいので、
    -- 英数字トークンか短めの語だけ本文検索する
    local is_ascii = tok:match("^[%w_]+$") ~= nil
    if is_ascii or vim.fn.strchars(tok) <= 16 then
      local args = { "rg", "-l", "-i", "-F", tok }
      for _, g in ipairs(RG_GLOBS) do
        table.insert(args, "--glob")
        table.insert(args, g)
      end
      local ok, proc = pcall(vim.system, args, { cwd = root, text = true })
      if ok then
        local result = proc:wait()
        if result.code == 0 or result.code == 1 then
          for _, line in ipairs(vim.split(result.stdout or "", "\n", { plain = true })) do
            if line ~= "" and not seen[line] and not skip[line] and not is_read_noise(line) then
              seen[line] = true
              table.insert(paths, line)
            end
            if #paths >= max_files then
              break
            end
          end
        end
      end
    end
  end
  return paths
end

--- 読むモード用: トピックに関連しそうな候補パスを集める（実在する tracked ファイルのみ）
--- パス一致した seed から import を上下（エントリポイント側・コアロジック側）に辿り、
--- 依存で繋がるファイルだけを「上流 → コア」の順で返す。
function M.gather_read_candidates(topic, max_files)
  max_files = max_files or 80
  local root = M.repo_root()
  if not root then
    return {}
  end

  local trace = require("storyline.trace")

  local tokens = read_tokens(topic)
  if #tokens == 0 and topic and topic ~= "" then
    table.insert(tokens, topic)
  end

  -- tracked + 未コミット（ignore されていないもの）を候補にする
  local all = run({ "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard" }) or {}

  -- パス一致 = seed（強い候補）
  local seeds, seed_set = {}, {}
  for _, path in ipairs(all) do
    if path:sub(1, 1) ~= "/" and not is_read_noise(path) then
      local lower = path:lower()
      for _, tok in ipairs(tokens) do
        if lower:find(tok:lower(), 1, true) then
          seed_set[path] = true
          table.insert(seeds, path)
          break
        end
      end
    end
  end

  -- seed が多すぎるときは実装優先・短いパス優先で刈る（トレースの起点として十分な数）
  if #seeds > 40 then
    table.sort(seeds, function(a, b)
      local ta, tb = trace.is_test_path(a), trace.is_test_path(b)
      if ta ~= tb then
        return not ta
      end
      if #a ~= #b then
        return #a < #b
      end
      return a < b
    end)
    for i = #seeds, 41, -1 do
      seeds[i] = nil
    end
  end

  local content = content_matches(root, tokens, seed_set, max_files)

  if #seeds > 0 then
    local result = trace.trace({
      seeds = seeds,
      candidates = content,
      all_paths = all,
      read_lines = function(path)
        return M.read_lines(path)
      end,
      search_refs = function(keys)
        return search_refs(root, keys)
      end,
      is_noise = is_read_noise,
      max_files = max_files,
    })
    if #result.paths > 0 then
      return result.paths
    end
  end

  -- seed が無い（トピックがパスに現れない）ときは本文一致で返す。
  -- 本文一致はテストに偏りやすい（テストは仕様の文言を多く含む）ので実装を優先し、
  -- テストは実装がひとつも見つからないときだけ返す
  local impl, tests = {}, {}
  for _, path in ipairs(content) do
    if trace.is_test_path(path) then
      table.insert(tests, path)
    else
      table.insert(impl, path)
    end
  end
  local paths = #impl > 0 and impl or tests
  if #paths < 10 then
    local seen = {}
    for _, p in ipairs(paths) do
      seen[p] = true
    end
    for _, path in ipairs(all) do
      if
        not seen[path]
        and not is_read_noise(path)
        and not trace.is_test_path(path)
        and (
          path:match("%.[tj]sx?$")
          or path:match("%.lua$")
          or path:match("%.py$")
          or path:match("%.go$")
          or path:match("%.graphql$")
          or path:match("%.gql$")
        )
      then
        seen[path] = true
        table.insert(paths, path)
      end
      if #paths >= 40 then
        break
      end
    end
  end
  table.sort(paths)
  return paths
end

--- 切り口で選んだファイル群と import で繋がる上流・下流だけを候補から残す
function M.chain_read_candidates(paths, picked)
  if not picked or #picked == 0 then
    return paths
  end
  local trace = require("storyline.trace")
  local out = trace.chain(paths, function(path)
    return M.read_lines(path)
  end, picked)
  if #out == 0 then
    return picked
  end
  return out
end

local REFINE_STOP = {
  ["除外"] = true,
  ["除く"] = true,
  ["なし"] = true,
  ["いらない"] = true,
  ["exclude"] = true,
  ["だけ"] = true,
  ["のみ"] = true,
  ["only"] = true,
  ["配下"] = true,
  ["以下"] = true,
  ["under"] = true,
}

local function refine_mode(instruction)
  local lower = instruction:lower()
  if
    instruction:find("除外", 1, true)
    or instruction:find("除く", 1, true)
    or instruction:find("なし", 1, true)
    or instruction:find("いらない", 1, true)
    or lower:find("exclude", 1, true)
  then
    return "exclude"
  end
  if instruction:find("配下", 1, true) or instruction:find("以下", 1, true) or lower:find("under", 1, true) then
    return "under"
  end
  if instruction:find("だけ", 1, true) or instruction:find("のみ", 1, true) or lower:find("only", 1, true) then
    return "only"
  end
  return "include"
end

local function path_under(path, prefix)
  local p = path:lower()
  local pre = prefix:lower():gsub("/+$", "")
  if pre == "" then
    return false
  end
  return p == pre or vim.startswith(p, pre .. "/")
end

--- 読むモード: 対話での絞り込み指示を候補パスに適用
--- instruction 例: "migration 除外" / "graphql だけ" / "worker 配下"
function M.refine_read_candidates(paths, instruction)
  instruction = vim.trim(instruction or "")
  if instruction == "" or not paths or #paths == 0 then
    return paths or {}
  end

  local mode = refine_mode(instruction)
  local words = {}
  for tok in instruction:gmatch("%S+") do
    if not REFINE_STOP[tok] and not REFINE_STOP[tok:lower()] then
      table.insert(words, tok)
    end
  end
  if #words == 0 then
    return vim.deepcopy(paths)
  end

  local result = paths
  for _, word in ipairs(words) do
    local needle = word:lower()
    local next_paths = {}
    for _, path in ipairs(result) do
      local lower = path:lower()
      local hit
      if mode == "under" then
        hit = path_under(path, word)
      else
        hit = lower:find(needle, 1, true) ~= nil
      end
      if mode == "exclude" then
        if not hit then
          table.insert(next_paths, path)
        end
      else
        -- include / only / under: ヒットしたものだけ残す
        if hit then
          table.insert(next_paths, path)
        end
      end
    end
    result = next_paths
  end
  return result
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

--- 指定ファイルのみの diff を取得し、1ファイルあたり max_lines 行に丸めて文字列で返す
function M.files_diff(mb, paths, max_lines)
  local args = { "git", "diff", "-M", mb, "--" }
  vim.list_extend(args, paths)
  local lines = run(args) or {}
  return table.concat(M.truncate_diff(lines, max_lines), "\n")
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
