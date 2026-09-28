--- StorylineRead 用の依存トレース。
--- import / require を静的に解析して「どのファイルがどのファイルを呼ぶか」を辿り、
--- トピックに文字列一致しただけの候補を「上流（エントリポイント）→ コアロジック」の
--- 連結成分へ絞り込む。ファイル読みと全文検索は関数注入で受け取る純ロジック。
local M = {}

local SRC_EXTS = { "ts", "tsx", "js", "jsx", "mjs", "cjs", "vue", "svelte", "lua", "py", "rb", "go" }
local INDEX_EXTS = { "ts", "tsx", "js", "jsx", "mjs", "cjs" }
-- ディレクトリ import の実体になりうる基名。逆参照キーとしては一般的すぎるので親を使う
local GENERIC_STEMS = { index = true, init = true, __init__ = true, main = true, mod = true }

local DEFAULT_MAX_FILES = 60
local DEFAULT_MAX_DEPTH = 3

local function ext_of(path)
  return (path:match("%.([%w]+)$") or ""):lower()
end

local function dirname(path)
  return path:match("^(.*)/[^/]+$") or ""
end

local function basename(path)
  return path:match("([^/]+)$") or path
end

local function strip_ext(path)
  return path:match("^(.+)%.[%w]+$") or path
end

--- ./ と ../ を解決してパスを正規化する
local function normalize(path)
  local parts = {}
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then
      table.remove(parts)
    elseif seg ~= "." then
      table.insert(parts, seg)
    end
  end
  return table.concat(parts, "/")
end

local function ends_with_path(path, suffix)
  if suffix == "" then
    return false
  end
  return path == suffix or path:sub(-(#suffix + 1)) == "/" .. suffix
end

function M.is_test_path(path)
  local lower = path:lower()
  return lower:match("_spec%.[%w]+$") ~= nil
    or lower:match("%.spec%.[%w]+$") ~= nil
    or lower:match("%.test%.[%w]+$") ~= nil
    or lower:match("_test%.[%w]+$") ~= nil
    or lower:match("^tests?/") ~= nil
    or lower:match("/tests?/") ~= nil
    or lower:find("/__tests__/", 1, true) ~= nil
    or lower:find("/spec/", 1, true) ~= nil
end

--- ファイルの拡張子に応じて import / require の指定子を抜き出す
--- require_relative は相対扱いにするため "./" を付けて返す
function M.parse_imports(path, lines)
  local ext = ext_of(path)
  local specs, seen = {}, {}
  local function add(spec)
    if spec and spec ~= "" and not seen[spec] then
      seen[spec] = true
      table.insert(specs, spec)
    end
  end

  local is_jsish = ext == "ts"
    or ext == "tsx"
    or ext == "js"
    or ext == "jsx"
    or ext == "mjs"
    or ext == "cjs"
    or ext == "vue"
    or ext == "svelte"

  local in_go_import = false
  for _, line in ipairs(lines) do
    if ext == "lua" then
      for spec in line:gmatch([=[require%s*%(?%s*["']([^"']+)["']]=]) do
        add(spec)
      end
    elseif is_jsish then
      for spec in line:gmatch([=[from%s+["']([^"']+)["']]=]) do
        add(spec)
      end
      for spec in line:gmatch([=[require%s*%(%s*["']([^"']+)["']%s*%)]=]) do
        add(spec)
      end
      for spec in line:gmatch([=[import%s*%(%s*["']([^"']+)["']%s*%)]=]) do
        add(spec)
      end
      add(line:match([=[^%s*import%s+["']([^"']+)["']]=]))
    elseif ext == "py" then
      add(line:match("^%s*from%s+([%w_%.]+)%s+import"))
      if not line:match("^%s*from") then
        local imported = line:match("^%s*import%s+(.+)$")
        if imported then
          for mod in imported:gmatch("([%w_%.]+)") do
            if mod ~= "as" then
              add(mod)
            end
          end
        end
      end
    elseif ext == "rb" then
      local rel = line:match([=[require_relative%s+["']([^"']+)["']]=])
      if rel then
        add(rel:match("^%.") and rel or ("./" .. rel))
      end
      add(line:match([=[^%s*require%s+["']([^"']+)["']]=]))
    elseif ext == "go" then
      if line:match("^%s*import%s*%(") then
        in_go_import = true
      elseif in_go_import and line:match("^%s*%)") then
        in_go_import = false
      end
      local spec = line:match('^%s*import%s+[%w_%.]*%s*"([^"]+)"')
      if not spec and in_go_import then
        spec = line:match('^%s*[%w_%.]*%s*"([^"]+)"%s*$')
      end
      add(spec)
    end
  end
  return specs
end

--- tracked パスの一覧から解決用インデックスを作る
function M.build_index(all_paths)
  local index = { exact = {}, by_stem = {} }
  for _, path in ipairs(all_paths) do
    index.exact[path] = true
    local stem = strip_ext(basename(path))
    local bucket = index.by_stem[stem]
    if not bucket then
      bucket = {}
      index.by_stem[stem] = bucket
    end
    table.insert(bucket, path)
  end
  return index
end

--- パス末尾一致で候補を探す。4件以上一致する一般的な名前は諦める
local function suffix_lookup(suffix, index, add)
  suffix = normalize(suffix)
  if suffix == "" then
    return
  end
  local stem = strip_ext(basename(suffix))
  local hits = {}
  for _, path in ipairs(index.by_stem[stem] or {}) do
    if ends_with_path(strip_ext(path), strip_ext(suffix)) then
      table.insert(hits, path)
    end
  end
  if #hits == 0 then
    for name in pairs(GENERIC_STEMS) do
      for _, path in ipairs(index.by_stem[name] or {}) do
        if ends_with_path(dirname(path), suffix) then
          table.insert(hits, path)
        end
      end
    end
  end
  if #hits > 3 then
    return
  end
  for _, path in ipairs(hits) do
    add(path)
  end
end

--- spec を importer から見て実ファイルへ解決する。返り値はパスの配列（0〜3件程度）
function M.resolve(spec, importer, index)
  spec = spec:gsub("[?#].*$", "")
  if spec == "" then
    return {}
  end

  local out, seen = {}, {}
  local function add(path)
    if path and index.exact[path] and path ~= importer and not seen[path] then
      seen[path] = true
      table.insert(out, path)
    end
  end
  local function try_bases(base)
    base = normalize(base)
    if base == "" then
      return
    end
    if base:match("%.[%w]+$") then
      add(base)
    end
    for _, e in ipairs(SRC_EXTS) do
      add(base .. "." .. e)
    end
    add(base .. "/init.lua")
    add(base .. "/__init__.py")
    for _, e in ipairs(INDEX_EXTS) do
      add(base .. "/index." .. e)
    end
  end

  local dir = dirname(importer)
  local iext = ext_of(importer)

  -- 相対パス（./ ../）
  if spec:sub(1, 2) == "./" or spec:sub(1, 3) == "../" then
    try_bases((dir ~= "" and dir .. "/" or "") .. spec)
    return out
  end

  -- Python の相対 import（.foo / ..foo.bar）
  if iext == "py" then
    local dots, rest = spec:match("^(%.+)([%w_%.]*)$")
    if dots then
      local parts = {}
      for seg in dir:gmatch("[^/]+") do
        table.insert(parts, seg)
      end
      for _ = 1, #dots - 1 do
        table.remove(parts)
      end
      local base = table.concat(parts, "/")
      if rest ~= "" then
        base = (base ~= "" and base .. "/" or "") .. rest:gsub("%.", "/")
      end
      try_bases(base)
      return out
    end
  end

  -- ドット区切りモジュール（Lua / Python）
  if (iext == "lua" or iext == "py") and spec:find("%.") and not spec:find("/") then
    local slashed = spec:gsub("%.", "/")
    try_bases(slashed)
    try_bases("lua/" .. slashed)
    try_bases("src/" .. slashed)
    if #out == 0 then
      suffix_lookup(slashed, index, add)
    end
    return out
  end

  -- パス風 spec（tsconfig の @/ エイリアスや monorepo パッケージを含む）
  if spec:find("/") then
    if spec:match("^@[^/]+/[^/]+$") then
      -- サブパスのないスコープ付きパッケージは npm とみなして無視
      return out
    end
    local cleaned = spec:gsub("^[@~#]/", ""):gsub("^@[^/]+/", "")
    try_bases(cleaned)
    try_bases("src/" .. cleaned)
    if #out == 0 then
      suffix_lookup(strip_ext(cleaned), index, add)
    end
    return out
  end

  -- スラッシュもドットもない単一名。npm / 標準ライブラリの可能性が高いので
  -- Lua / Ruby のときだけ拾う
  if iext == "lua" or iext == "rb" then
    try_bases(spec)
    try_bases("lua/" .. spec)
    try_bases("lib/" .. spec)
  end
  return out
end

local TEST_SUFFIXES = { ".test", ".spec", "_test", "_spec" }

--- テストの基名からテスト対象の実装名を推定する（"foo.test" → "foo"）
local function test_stem_subject(stem)
  for _, suffix in ipairs(TEST_SUFFIXES) do
    local base = stem:match("^(.+)" .. suffix:gsub("%.", "%%.") .. "$")
    if base then
      return base
    end
  end
  return stem
end

--- テストが置かれるディレクトリから実装側のディレクトリを推定する
local function test_dir_subject(dir)
  return dir:gsub("/__tests__$", ""):gsub("/tests?$", "")
end

--- path のコロケーションテスト（同ディレクトリ、または直下の __tests__/ tests/ に
--- ある同名のテストファイル）を探す
function M.colocated_tests(path, index)
  if M.is_test_path(path) then
    return {}
  end
  local stem = strip_ext(basename(path))
  local dir = dirname(path)
  local out, seen = {}, {}
  local function add(p)
    if not seen[p] and p ~= path and M.is_test_path(p) and test_dir_subject(dirname(p)) == dir then
      seen[p] = true
      table.insert(out, p)
    end
  end
  for _, suffix in ipairs(TEST_SUFFIXES) do
    for _, p in ipairs(index.by_stem[stem .. suffix] or {}) do
      add(p)
    end
  end
  -- __tests__/foo.ts のような、同名のままテストディレクトリに置くパターン
  for _, p in ipairs(index.by_stem[stem] or {}) do
    add(p)
  end
  return out
end

--- テストのコロケーション先（対象実装）を paths の中から命名規則で探す
--- 例: "src/services/__tests__/export.test.ts" → "src/services/export.ts"
function M.test_subject(test, paths)
  if not M.is_test_path(test) then
    return nil
  end
  local want_stem = test_stem_subject(strip_ext(basename(test)))
  local want_dir = test_dir_subject(dirname(test))
  for _, path in ipairs(paths) do
    if
      path ~= test
      and not M.is_test_path(path)
      and dirname(path) == want_dir
      and strip_ext(basename(path)) == want_stem
    then
      return path
    end
  end
  return nil
end

--- 逆参照（このファイルを import している側）を全文検索するためのキー
--- 例: "src/services/export/report.ts" → { "export/report", "export.report" }
function M.ref_keys(path)
  local base = strip_ext(basename(path))
  local dir = dirname(path)
  if GENERIC_STEMS[base] then
    base = dir:match("([^/]+)$")
    dir = dirname(dir)
  end
  if not base or base == "" then
    return {}
  end
  local parent = dir:match("([^/]+)$")
  if parent and parent ~= "" then
    return { parent .. "/" .. base, parent .. "." .. base }
  end
  if #base >= 4 then
    return { base }
  end
  return {}
end

--- import グラフの構築ヘルパ。read_lines が nil を返すファイルはエッジなし扱い
local function make_imports_of(index, read_lines, is_noise)
  local cache = {}
  return function(path)
    local cached = cache[path]
    if cached then
      return cached
    end
    local resolved, seen = {}, {}
    local lines = read_lines(path)
    if lines then
      for _, spec in ipairs(M.parse_imports(path, lines)) do
        for _, target in ipairs(M.resolve(spec, path, index)) do
          if target ~= path and not seen[target] and not is_noise(target) then
            seen[target] = true
            table.insert(resolved, target)
          end
        end
      end
    end
    cache[path] = resolved
    return resolved
  end
end

--- エントリポイント（集合内のテスト以外から import されていないファイル）から
--- 呼び出し順に並べ替える。テストは import 先の実装の直後に置く（コロケーション）。
--- returns ordered_paths, roles({ [path] = "entry"|"core"|"test" })
function M.order(paths, edges)
  local set = {}
  for _, path in ipairs(paths) do
    set[path] = true
  end

  local imports_by, importers_by = {}, {}
  for _, edge in ipairs(edges) do
    local from, to = edge[1], edge[2]
    if set[from] and set[to] then
      imports_by[from] = imports_by[from] or {}
      table.insert(imports_by[from], to)
      importers_by[to] = importers_by[to] or {}
      table.insert(importers_by[to], from)
    end
  end

  local mains, tests = {}, {}
  for _, path in ipairs(paths) do
    if M.is_test_path(path) then
      table.insert(tests, path)
    else
      table.insert(mains, path)
    end
  end

  -- エントリ = テスト以外から import されず、自分は import 先を持つノード。
  -- どこにも繋がらない孤立ファイルはエントリではなく周辺（深さ最大）として扱う
  local has_main_importer = {}
  for _, path in ipairs(mains) do
    for _, from in ipairs(importers_by[path] or {}) do
      if not M.is_test_path(from) then
        has_main_importer[path] = true
        break
      end
    end
  end
  local entries = {}
  for _, path in ipairs(mains) do
    if not has_main_importer[path] and imports_by[path] and #imports_by[path] > 0 then
      table.insert(entries, path)
    end
  end
  if #entries == 0 then
    for _, path in ipairs(mains) do
      if not has_main_importer[path] then
        table.insert(entries, path)
      end
    end
  end
  if #entries == 0 and mains[1] then
    -- 全部が循環しているときの保険
    entries = { mains[1] }
  end

  -- エントリからの呼び出し距離（BFS）
  local depth, queue = {}, {}
  for _, path in ipairs(entries) do
    depth[path] = 0
    table.insert(queue, path)
  end
  local qi = 1
  while queue[qi] do
    local cur = queue[qi]
    qi = qi + 1
    for _, target in ipairs(imports_by[cur] or {}) do
      if depth[target] == nil and not M.is_test_path(target) then
        depth[target] = depth[cur] + 1
        table.insert(queue, target)
      end
    end
  end
  local deepest = 0
  for _, d in pairs(depth) do
    deepest = math.max(deepest, d)
  end
  for _, path in ipairs(mains) do
    if depth[path] == nil then
      depth[path] = deepest + 1
    end
  end

  table.sort(mains, function(a, b)
    if depth[a] ~= depth[b] then
      return depth[a] < depth[b]
    end
    return a < b
  end)

  local roles = {}
  local entry_set = {}
  for _, path in ipairs(entries) do
    entry_set[path] = true
  end
  for _, path in ipairs(mains) do
    roles[path] = entry_set[path] and "entry" or "core"
  end

  local ordered = {}
  for _, path in ipairs(mains) do
    table.insert(ordered, path)
  end

  -- テストは「import している実装のうち最も深いもの」の直後へ差し込む
  table.sort(tests)
  for _, test in ipairs(tests) do
    roles[test] = "test"
    local subject, best = nil, -1
    for _, target in ipairs(imports_by[test] or {}) do
      if not M.is_test_path(target) and (depth[target] or -1) > best then
        best = depth[target]
        subject = target
      end
    end
    if not subject then
      -- import が解決できないときは、コロケーションの命名から対象を推定する
      subject = M.test_subject(test, mains)
    end
    local anchor = nil
    if subject then
      for i, path in ipairs(ordered) do
        if path == subject then
          anchor = i
          break
        end
      end
    end
    if anchor then
      local pos = anchor + 1
      while ordered[pos] and M.is_test_path(ordered[pos]) do
        pos = pos + 1
      end
      table.insert(ordered, pos, test)
    else
      table.insert(ordered, test)
    end
  end

  return ordered, roles
end

--- 確定済みの候補集合に、集合内の import 関係・並び順・役割を注釈する
--- （候補の増減はしない。プロンプトと表示順に使う）
--- returns { paths, edges = { {from, to} }, roles }
function M.annotate(paths, read_lines)
  local index = M.build_index(paths)
  local imports_of = make_imports_of(index, read_lines, function(_)
    return false
  end)

  local edges = {}
  for _, path in ipairs(paths) do
    for _, target in ipairs(imports_of(path)) do
      table.insert(edges, { path, target })
    end
  end

  local ordered, roles = M.order(paths, edges)
  return { paths = ordered, edges = edges, roles = roles }
end

--- picked（切り口で選んだファイル）と import で繋がる上流・下流だけを paths から残す
function M.chain(paths, read_lines, picked)
  local annotated = M.annotate(paths, read_lines)

  local imports_by, importers_by = {}, {}
  for _, edge in ipairs(annotated.edges) do
    local from, to = edge[1], edge[2]
    imports_by[from] = imports_by[from] or {}
    table.insert(imports_by[from], to)
    importers_by[to] = importers_by[to] or {}
    table.insert(importers_by[to], from)
  end

  local keep, queue = {}, {}
  for _, path in ipairs(picked) do
    if not keep[path] then
      keep[path] = true
      table.insert(queue, path)
    end
  end
  local qi = 1
  while queue[qi] do
    local cur = queue[qi]
    qi = qi + 1
    for _, list in ipairs({ imports_by[cur], importers_by[cur] }) do
      for _, nxt in ipairs(list or {}) do
        if not keep[nxt] then
          keep[nxt] = true
          table.insert(queue, nxt)
        end
      end
    end
  end

  local out = {}
  for _, path in ipairs(annotated.paths) do
    if keep[path] then
      table.insert(out, path)
    end
  end
  return out
end

--- seed（パス一致した強い候補）から import を上下に辿り、
--- 繋がるファイルだけの一覧を「上流 → コア」の順で返す。
--- opts:
---   seeds: string[]                     -- パス一致した強い候補
---   candidates?: string[]               -- 本文一致などの弱い候補（繋がるものだけ残る）
---   all_paths: string[]                 -- tracked ファイル全件（import の解決に使う）
---   read_lines: fun(path):string[]|nil
---   search_refs?: fun(keys: string[]):string[]  -- 逆参照候補の全文検索
---   is_noise?: fun(path):boolean
---   max_files?: number, max_depth?: number
--- returns { paths, edges = { {from, to} }, roles }
function M.trace(opts)
  local seeds = opts.seeds or {}
  if #seeds == 0 then
    return { paths = {}, edges = {}, roles = {} }
  end
  local max_files = opts.max_files or DEFAULT_MAX_FILES
  local max_depth = opts.max_depth or DEFAULT_MAX_DEPTH
  local is_noise = opts.is_noise or function(_)
    return false
  end

  local index = M.build_index(opts.all_paths or {})
  local imports_of = make_imports_of(index, opts.read_lines, is_noise)

  local kept, order = {}, {}
  local function keep(path)
    if kept[path] or is_noise(path) or #order >= max_files then
      return false
    end
    kept[path] = true
    table.insert(order, path)
    return true
  end

  for _, seed in ipairs(seeds) do
    keep(seed)
  end

  -- 下流: seed が import している先（コアロジック側）を深さ max_depth まで。
  -- テストは本筋（上流 → コア）に入れない
  local frontier = {}
  for _, seed in ipairs(seeds) do
    table.insert(frontier, seed)
  end
  for _ = 1, max_depth do
    local next_frontier = {}
    for _, path in ipairs(frontier) do
      for _, target in ipairs(imports_of(path)) do
        if not M.is_test_path(target) and keep(target) then
          table.insert(next_frontier, target)
        end
      end
    end
    if #next_frontier == 0 then
      break
    end
    frontier = next_frontier
  end

  -- 上流: seed を import している側（エントリポイント側）を2段まで
  if opts.search_refs then
    local targets = seeds
    for _ = 1, 2 do
      local keys, target_set = {}, {}
      for _, path in ipairs(targets) do
        target_set[path] = true
        for _, key in ipairs(M.ref_keys(path)) do
          table.insert(keys, key)
        end
      end
      if #keys == 0 or #order >= max_files then
        break
      end
      local added = {}
      for _, path in ipairs(opts.search_refs(keys) or {}) do
        -- テストはモジュールを最も多く import している側なので、ここで拾うと
        -- 一覧がテストで埋まる。エントリポイント探しではテストを除外する
        if not kept[path] and not is_noise(path) and not M.is_test_path(path) then
          -- 実際に import しているかを解決して確かめる（検索ヒットだけでは入れない）
          for _, target in ipairs(imports_of(path)) do
            if target_set[target] then
              if keep(path) then
                table.insert(added, path)
              end
              break
            end
          end
        end
      end
      if #added == 0 then
        break
      end
      targets = added
    end
  end

  -- 本文一致だけの弱い候補は、確定した集合を import している実装だけ残す（テストは除外）
  for _, path in ipairs(opts.candidates or {}) do
    if not kept[path] and not is_noise(path) and not M.is_test_path(path) then
      for _, target in ipairs(imports_of(path)) do
        if kept[target] then
          keep(path)
          break
        end
      end
    end
  end

  -- テストが入る経路はここだけ: 残った実装のコロケーションテスト
  -- （同ディレクトリ、または直下の __tests__/ tests/ にある同名テスト）
  local spine = {}
  for _, path in ipairs(order) do
    table.insert(spine, path)
  end
  for _, path in ipairs(spine) do
    if not M.is_test_path(path) then
      for _, test in ipairs(M.colocated_tests(path, index)) do
        keep(test)
      end
    end
  end

  -- 集合内で閉じたエッジを確定
  local edges = {}
  for _, path in ipairs(order) do
    for _, target in ipairs(imports_of(path)) do
      if kept[target] then
        table.insert(edges, { path, target })
      end
    end
  end

  local ordered, roles = M.order(order, edges)
  return { paths = ordered, edges = edges, roles = roles }
end

return M
