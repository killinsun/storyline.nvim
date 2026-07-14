local schema = require("storyline.ai.schema")
local git = require("storyline.git")

local FILES = {
  { path = "src/auth/session.ts", status = "M", added = 10, deleted = 2 },
  { path = "src/auth/middleware.ts", status = "A", added = 30, deleted = 0 },
  { path = "docs/README.md", status = "M", added = 1, deleted = 1 },
}

describe("schema.validate", function()
  it("正常な AI 出力を正規化する", function()
    local story = schema.validate({
      title = "認証の追加",
      chapters = {
        {
          title = "認証フロー",
          summary = "セッション管理を追加",
          review_points = { "トークンの有効期限" },
          files = { "src/auth/session.ts", "src/auth/middleware.ts" },
        },
      },
    }, FILES)

    assert.is_not_nil(story)
    assert.equals("認証の追加", story.title)
    -- 割り当て漏れの docs/README.md は「その他の変更」に合成される
    assert.equals(2, #story.chapters)
    assert.equals("その他の変更", story.chapters[2].title)
    assert.same({ "docs/README.md" }, story.chapters[2].files)
  end)

  it("存在しないパスと重複割り当てを除外する", function()
    local story = schema.validate({
      chapters = {
        { title = "A", files = { "src/auth/session.ts", "made-up.ts" } },
        { title = "B", files = { "src/auth/session.ts", "src/auth/middleware.ts", "docs/README.md" } },
      },
    }, FILES)

    assert.is_not_nil(story)
    assert.same({ "src/auth/session.ts" }, story.chapters[1].files)
    assert.same({ "src/auth/middleware.ts", "docs/README.md" }, story.chapters[2].files)
  end)

  it("チャプターが作れない出力は nil を返す", function()
    assert.is_nil(schema.validate({ chapters = {} }, FILES))
    assert.is_nil(schema.validate("not a table", FILES))
    assert.is_nil(schema.validate({ chapters = { { files = { "unknown.ts" } } } }, FILES))
  end)
end)

describe("schema.fallback", function()
  it("トップレベルディレクトリ単位でグルーピングする", function()
    local story = schema.fallback(FILES)
    assert.equals(2, #story.chapters)
    local titles = { story.chapters[1].title, story.chapters[2].title }
    table.sort(titles)
    assert.same({ "docs", "src" }, titles)
  end)
end)

describe("git.truncate_diff", function()
  it("ファイルごとに上限行数で丸める", function()
    local lines = {
      "diff --git a/a.ts b/a.ts",
      "line1",
      "line2",
      "line3",
      "diff --git a/b.ts b/b.ts",
      "line1",
    }
    local out = git.truncate_diff(lines, 2)
    assert.same({
      "diff --git a/a.ts b/a.ts",
      "line1",
      "line2",
      "... (このファイルの diff は長いため省略)",
      "diff --git a/b.ts b/b.ts",
      "line1",
    }, out)
  end)
end)
