local trace = require("storyline.trace")

-- 疑似リポジトリ: routes/report.ts（エントリ）→ export.ts（seed）→ csv.ts → format.ts
local REPO = {
  ["src/routes/report.ts"] = { 'import { exportReport } from "../services/report/export"' },
  ["src/services/report/export.ts"] = { 'import { toCsv } from "./csv"' },
  ["src/services/report/csv.ts"] = { 'import { fmt } from "../../lib/format"' },
  ["src/lib/format.ts"] = { "export const fmt = (v: string) => v" },
  ["src/services/report/export.test.ts"] = { 'import { exportReport } from "./export"' },
  ["src/other/noise.ts"] = { 'import fs from "fs"' },
  -- コロケーションでないテスト（seed を import していても一覧に入れない）
  ["tests/integration/report_flow.test.ts"] = {
    'import { exportReport } from "../../src/services/report/export"',
  },
}

local ALL_PATHS = vim.tbl_keys(REPO)
table.sort(ALL_PATHS)

local function read_lines(path)
  return REPO[path]
end

describe("trace.parse_imports", function()
  it("TypeScript の import / require / dynamic import を抜き出す", function()
    local specs = trace.parse_imports("a.ts", {
      'import { x } from "./x"',
      'export { y } from "../y"',
      'const z = require("@/lib/z")',
      'const w = await import("./w")',
      'import "./side-effect"',
      'import notThis from "react"',
    })
    assert.same({ "./x", "../y", "@/lib/z", "./w", "./side-effect", "react" }, specs)
  end)

  it("Lua の require を抜き出す", function()
    local specs = trace.parse_imports("a.lua", {
      'local git = require("storyline.git")',
      "local ui = require('storyline.ui.main')",
      'require "plenary"',
    })
    assert.same({ "storyline.git", "storyline.ui.main", "plenary" }, specs)
  end)

  it("Python の from / import を抜き出す", function()
    local specs = trace.parse_imports("a.py", {
      "from app.services import export",
      "import app.lib.csv",
      "from .sibling import thing",
    })
    assert.same({ "app.services", "app.lib.csv", ".sibling" }, specs)
  end)

  it("Ruby の require_relative は相対パス扱いにする", function()
    local specs = trace.parse_imports("a.rb", {
      'require_relative "helper"',
      'require "json"',
    })
    assert.same({ "./helper", "json" }, specs)
  end)
end)

describe("trace.resolve", function()
  local index = trace.build_index({
    "src/services/report/export.ts",
    "src/services/report/csv.ts",
    "src/lib/format.ts",
    "src/lib/util/index.ts",
    "lua/storyline/git.lua",
  })

  it("相対 import を拡張子補完つきで解決する", function()
    assert.same({ "src/services/report/csv.ts" }, trace.resolve("./csv", "src/services/report/export.ts", index))
    assert.same({ "src/lib/format.ts" }, trace.resolve("../../lib/format", "src/services/report/csv.ts", index))
  end)

  it("ディレクトリ import は index ファイルへ解決する", function()
    assert.same({ "src/lib/util/index.ts" }, trace.resolve("../lib/util", "src/routes/report.ts", index))
  end)

  it("@/ エイリアスを末尾一致で解決する", function()
    assert.same({ "src/lib/format.ts" }, trace.resolve("@/lib/format", "src/routes/report.ts", index))
  end)

  it("Lua のドット区切り require を解決する", function()
    assert.same({ "lua/storyline/git.lua" }, trace.resolve("storyline.git", "lua/storyline/init.lua", index))
  end)

  it("npm パッケージは解決しない", function()
    assert.same({}, trace.resolve("react", "src/routes/report.ts", index))
    assert.same({}, trace.resolve("@scope/pkg", "src/routes/report.ts", index))
  end)
end)

describe("trace.trace", function()
  local function run_trace()
    return trace.trace({
      seeds = { "src/services/report/export.ts" },
      candidates = {
        "src/services/report/export.test.ts",
        "tests/integration/report_flow.test.ts",
        "src/other/noise.ts",
      },
      all_paths = ALL_PATHS,
      read_lines = read_lines,
      search_refs = function(keys)
        -- seed の逆参照キー（親ディレクトリ/基名）で検索されたときだけヒットを返す
        if vim.tbl_contains(keys, "report/export") then
          return { "src/routes/report.ts", "src/other/noise.ts", "tests/integration/report_flow.test.ts" }
        end
        return {}
      end,
    })
  end

  it("seed から上流・下流を辿り、繋がらない候補を落とす", function()
    local result = run_trace()
    local set = {}
    for _, p in ipairs(result.paths) do
      set[p] = true
    end
    -- 上流（エントリポイント）と下流（コアロジック）が入る
    assert.is_true(set["src/routes/report.ts"])
    assert.is_true(set["src/services/report/csv.ts"])
    assert.is_true(set["src/lib/format.ts"])
    -- コロケーションテストは残り、無関係な本文一致は落ちる
    assert.is_true(set["src/services/report/export.test.ts"])
    assert.is_nil(set["src/other/noise.ts"])
    -- seed を import していても、コロケーションでないテストは入れない
    assert.is_nil(set["tests/integration/report_flow.test.ts"])
  end)

  it(
    "エントリポイント → コアロジックの順に並び、テストは実装の直後（コロケーション）",
    function()
      local result = run_trace()
      assert.same({
        "src/routes/report.ts",
        "src/services/report/export.ts",
        "src/services/report/export.test.ts",
        "src/services/report/csv.ts",
        "src/lib/format.ts",
      }, result.paths)
      assert.equals("entry", result.roles["src/routes/report.ts"])
      assert.equals("core", result.roles["src/services/report/csv.ts"])
      assert.equals("test", result.roles["src/services/report/export.test.ts"])
    end
  )

  it("seed が無ければ空を返す（呼び出し側でフォールバック）", function()
    local result = trace.trace({ seeds = {}, all_paths = ALL_PATHS, read_lines = read_lines })
    assert.same({}, result.paths)
  end)

  it("max_files で総数を打ち切る", function()
    local result = trace.trace({
      seeds = { "src/services/report/export.ts" },
      all_paths = ALL_PATHS,
      read_lines = read_lines,
      max_files = 2,
    })
    assert.equals(2, #result.paths)
  end)
end)

describe("trace.annotate / trace.chain", function()
  local paths = {
    "src/routes/report.ts",
    "src/services/report/export.ts",
    "src/services/report/csv.ts",
    "src/lib/format.ts",
    "src/other/noise.ts",
  }

  it("annotate は集合内のエッジと並び順を返す（候補は増減しない）", function()
    local annotated = trace.annotate(paths, read_lines)
    assert.equals(#paths, #annotated.paths)
    -- 繋がりのない noise.ts は末尾（深さ最大扱い）
    assert.equals("src/routes/report.ts", annotated.paths[1])
    assert.equals("src/other/noise.ts", annotated.paths[#annotated.paths])
    assert.is_true(#annotated.edges >= 3)
  end)

  it("chain は選んだファイルと import で繋がるものだけ残す", function()
    local out = trace.chain(paths, read_lines, { "src/services/report/csv.ts" })
    assert.same({
      "src/routes/report.ts",
      "src/services/report/export.ts",
      "src/services/report/csv.ts",
      "src/lib/format.ts",
    }, out)
  end)
end)

describe("trace.colocated_tests", function()
  local index = trace.build_index({
    "src/services/export.ts",
    "src/services/export.test.ts",
    "src/services/__tests__/export.test.ts",
    "src/services/__tests__/export.ts",
    "src/other/export.test.ts",
    "lua/storyline/trace.lua",
    "lua/storyline/trace_spec.lua",
  })

  it("同ディレクトリと直下の __tests__ の同名テストだけ拾う", function()
    local tests = trace.colocated_tests("src/services/export.ts", index)
    table.sort(tests)
    assert.same({
      "src/services/__tests__/export.test.ts",
      "src/services/__tests__/export.ts",
      "src/services/export.test.ts",
    }, tests)
  end)

  it("_spec.lua のコロケーションを拾う", function()
    assert.same({ "lua/storyline/trace_spec.lua" }, trace.colocated_tests("lua/storyline/trace.lua", index))
  end)

  it("テスト自身には何も返さない", function()
    assert.same({}, trace.colocated_tests("src/services/export.test.ts", index))
  end)
end)

describe("trace.test_subject", function()
  local paths = {
    "src/services/export.ts",
    "src/services/export.test.ts",
    "src/services/__tests__/csv.test.ts",
    "src/services/csv.ts",
    "lua/storyline/trace.lua",
  }

  it("命名規則からコロケーション先の実装を返す", function()
    assert.equals("src/services/export.ts", trace.test_subject("src/services/export.test.ts", paths))
    assert.equals("src/services/csv.ts", trace.test_subject("src/services/__tests__/csv.test.ts", paths))
    assert.equals("lua/storyline/trace.lua", trace.test_subject("lua/storyline/trace_spec.lua", paths))
  end)

  it("対象が見つからない・テストでないときは nil", function()
    assert.is_nil(trace.test_subject("tests/integration/flow.test.ts", paths))
    assert.is_nil(trace.test_subject("src/services/export.ts", paths))
  end)
end)

describe("trace.is_test_path", function()
  it("テストらしいパスを判定する", function()
    assert.is_true(trace.is_test_path("src/a.test.ts"))
    assert.is_true(trace.is_test_path("src/a.spec.tsx"))
    assert.is_true(trace.is_test_path("lua/storyline/trace_spec.lua"))
    assert.is_true(trace.is_test_path("tests/foo.lua"))
    assert.is_true(trace.is_test_path("src/__tests__/a.ts"))
    assert.is_false(trace.is_test_path("src/attestation.ts"))
    assert.is_false(trace.is_test_path("src/special.ts"))
  end)
end)
