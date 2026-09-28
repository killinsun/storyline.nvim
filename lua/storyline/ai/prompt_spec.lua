local prompt = require("storyline.ai.prompt")

describe("prompt.build（PR レビュー）の依存トレース", function()
  local ctx = {
    files = {
      { path = "src/routes/report.ts", status = "M", added = 1, deleted = 0 },
      { path = "src/services/export.ts", status = "M", added = 2, deleted = 1 },
      { path = "src/services/export.test.ts", status = "A", added = 3, deleted = 0 },
    },
    stat = "",
    diff = "",
    trace = {
      edges = { { "src/routes/report.ts", "src/services/export.ts" } },
      roles = {
        ["src/routes/report.ts"] = "entry",
        ["src/services/export.test.ts"] = "test",
      },
    },
  }

  it("依存関係セクションと役割注釈が入る", function()
    local p = prompt.build(ctx)
    assert.is_truthy(p:find("# 依存関係", 1, true))
    assert.is_truthy(p:find("- src/routes/report.ts → src/services/export.ts", 1, true))
    assert.is_truthy(p:find("（エントリポイント候補）", 1, true))
    assert.is_truthy(p:find("（テスト）", 1, true))
  end)

  it("上流順とテストのコロケーションを指示する", function()
    local p = prompt.build(ctx)
    assert.is_truthy(p:find("エントリポイント（上流）", 1, true))
    assert.is_truthy(p:find("コロケーション", 1, true))
  end)

  it("trace が無ければ従来どおり", function()
    local p = prompt.build({ files = ctx.files, stat = "", diff = "" })
    assert.is_falsy(p:find("# 依存関係", 1, true))
    assert.is_truthy(p:find('"chapters"', 1, true))
  end)
end)

describe("prompt.build_read の依存トレース", function()
  local ctx = {
    topic = "レポートのエクスポート",
    files = {
      { path = "src/routes/report.ts", status = "M", added = 0, deleted = 0 },
      { path = "src/services/report/export.ts", status = "M", added = 0, deleted = 0 },
      { path = "src/services/report/export.test.ts", status = "M", added = 0, deleted = 0 },
    },
    trace = {
      edges = {
        { "src/routes/report.ts", "src/services/report/export.ts" },
        { "src/services/report/export.test.ts", "src/services/report/export.ts" },
      },
      roles = {
        ["src/routes/report.ts"] = "entry",
        ["src/services/report/export.ts"] = "core",
        ["src/services/report/export.test.ts"] = "test",
      },
    },
  }

  it("依存関係セクションとエッジが入る", function()
    local p = prompt.build_read(ctx)
    assert.is_truthy(p:find("# 依存関係", 1, true))
    assert.is_truthy(p:find("- src/routes/report.ts → src/services/report/export.ts", 1, true))
  end)

  it("候補一覧に役割の注釈が付く", function()
    local p = prompt.build_read(ctx)
    assert.is_truthy(p:find("- src/routes/report.ts（エントリポイント候補）", 1, true))
    assert.is_truthy(p:find("- src/services/report/export.test.ts（テスト）", 1, true))
    -- core は注釈なし
    assert.is_truthy(p:find("- src/services/report/export.ts\n", 1, true))
  end)

  it("テストのコロケーションと上流 → コアの並び順を指示する", function()
    local p = prompt.build_read(ctx)
    assert.is_truthy(p:find("コロケーション", 1, true))
    assert.is_truthy(p:find("エントリポイント（上流）", 1, true))
  end)

  it("trace が無くても従来どおり組み立てられる", function()
    local p = prompt.build_read({ topic = "CSVエクスポート", files = ctx.files })
    assert.is_falsy(p:find("# 依存関係", 1, true))
    assert.is_truthy(p:find("# 候補ファイル一覧", 1, true))
    assert.is_truthy(p:find("- src/routes/report.ts\n", 1, true))
  end)
end)
