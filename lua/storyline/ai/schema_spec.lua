local schema = require("storyline.ai.schema")

local FILES = {
  { path = "src/auth/session.ts", status = "M", added = 10, deleted = 2 },
  { path = "src/auth/middleware.ts", status = "A", added = 30, deleted = 0 },
  { path = "docs/README.md", status = "M", added = 1, deleted = 1 },
}

local DECODED = {
  title = "認証の追加",
  chapters = {
    {
      title = "認証フロー",
      summary = "セッション管理を追加",
      files = { "src/auth/session.ts" },
    },
  },
}

describe("schema.validate の leftover 制御", function()
  it(
    "デフォルトは割り当て漏れを「その他の変更」に合成する（PR レビュー用）",
    function()
      local story = schema.validate(DECODED, FILES)
      assert.is_not_nil(story)
      assert.equals(2, #story.chapters)
      assert.equals("その他の変更", story.chapters[2].title)
      assert.same({ "src/auth/middleware.ts", "docs/README.md" }, story.chapters[2].files)
    end
  )

  it("leftover = false なら AI が外したファイルはそのまま落とす（読むモード用）", function()
    local story = schema.validate(DECODED, FILES, { leftover = false })
    assert.is_not_nil(story)
    assert.equals(1, #story.chapters)
    assert.equals("認証フロー", story.chapters[1].title)
    assert.same({ "src/auth/session.ts" }, story.chapters[1].files)
  end)
end)

describe("schema.validate はコロケーションと上流順を徹底する", function()
  local FILES2 = {
    { path = "src/routes/report.ts", status = "M", added = 1, deleted = 0 },
    { path = "src/services/export.ts", status = "M", added = 1, deleted = 0 },
    { path = "src/services/export.test.ts", status = "M", added = 1, deleted = 0 },
  }

  it(
    "テストだけのチャプターを対象実装のチャプターへ吸収し、実装の直後に置く",
    function()
      local story = schema.validate({
        chapters = {
          { title = "実装", files = { "src/services/export.ts", "src/routes/report.ts" } },
          { title = "テスト", files = { "src/services/export.test.ts" } },
        },
      }, FILES2)
      assert.is_not_nil(story)
      assert.equals(1, #story.chapters)
      assert.same(
        { "src/services/export.ts", "src/services/export.test.ts", "src/routes/report.ts" },
        story.chapters[1].files
      )
    end
  )

  it("trace があればチャプター内を上流 → コアの順に並べ替える", function()
    local story = schema.validate(
      {
        chapters = {
          {
            title = "実装",
            files = { "src/services/export.ts", "src/routes/report.ts", "src/services/export.test.ts" },
          },
        },
      },
      FILES2,
      {
        trace = {
          paths = { "src/routes/report.ts", "src/services/export.ts", "src/services/export.test.ts" },
        },
      }
    )
    assert.is_not_nil(story)
    assert.same(
      { "src/routes/report.ts", "src/services/export.ts", "src/services/export.test.ts" },
      story.chapters[1].files
    )
  end)

  it("「その他の変更」に落ちたテストも対象実装のチャプターへ戻る", function()
    local story = schema.validate({
      chapters = {
        { title = "実装", files = { "src/services/export.ts", "src/routes/report.ts" } },
      },
    }, FILES2)
    assert.is_not_nil(story)
    -- leftover の export.test.ts が「その他の変更」ではなく実装チャプターに入る
    assert.equals(1, #story.chapters)
    assert.same(
      { "src/services/export.ts", "src/services/export.test.ts", "src/routes/report.ts" },
      story.chapters[1].files
    )
  end)
end)

describe("ai.analyze_read は leftover を合成しない (fake-ai との統合)", function()
  local config = require("storyline.config")

  after_each(function()
    config.setup({})
  end)

  it("fake-ai が選ばなかった候補は「その他の変更」に戻らない", function()
    local spec_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
    local fake_ai = vim.fs.normalize(spec_dir .. "/../../../tests/fixtures/fake-ai")

    config.setup({
      backend = "claude",
      backends = {
        claude = { cmd = "sh", args = { fake_ai } },
      },
    })

    local ai = require("storyline.ai")

    local done, story, err
    ai.analyze_read({ topic = "認証", files = FILES }, function(s, e)
      story = s
      err = e
      done = true
    end)

    vim.wait(5000, function()
      return done
    end)

    assert.is_true(done)
    assert.is_nil(err)
    assert.is_not_nil(story)
    assert.equals(1, #story.chapters)
    assert.same({ "src/auth/session.ts" }, story.chapters[1].files)
  end)
end)
