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

describe("ai.analyze (fake-ai との統合)", function()
  local config = require("storyline.config")

  -- テスト後に config をデフォルトへ戻す
  after_each(function()
    config.setup({})
  end)

  it("fake-ai の固定 JSON からチャプター構成を作る", function()
    local spec_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
    local fake_ai = spec_dir .. "/fixtures/fake-ai"

    config.setup({
      backend = "claude",
      backends = {
        claude = { cmd = "sh", args = { fake_ai } },
      },
    })

    local ai = require("storyline.ai")
    local ctx = {
      files = {
        { path = "src/auth/session.ts", status = "M", added = 10, deleted = 2 },
        { path = "docs/README.md", status = "M", added = 1, deleted = 1 },
      },
      stat = "",
      diff = "",
    }

    local done, story, err
    ai.analyze(ctx, function(s, e)
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
    assert.equals(2, #story.chapters)
    assert.same({ "src/auth/session.ts" }, story.chapters[1].files)
    assert.equals("その他の変更", story.chapters[2].title)
    assert.same({ "docs/README.md" }, story.chapters[2].files)
  end)
end)

describe("ai.ask (fake-ai との統合)", function()
  local config = require("storyline.config")

  -- テスト後に config をデフォルトへ戻す
  after_each(function()
    config.setup({})
  end)

  it("fake-ai の出力を自由テキストの回答として返す", function()
    local spec_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
    local fake_ai = spec_dir .. "/fixtures/fake-ai"

    config.setup({
      backend = "claude",
      backends = {
        claude = { cmd = "sh", args = { fake_ai } },
      },
    })

    local ai = require("storyline.ai")

    local done, text, err
    ai.ask("このチャプターについて教えてください", function(t, e)
      text = t
      err = e
      done = true
    end)

    vim.wait(5000, function()
      return done
    end)

    assert.is_true(done)
    assert.is_nil(err)
    assert.is_not_nil(text)
    assert.is_true(#text > 0)
  end)
end)

describe("プロンプトのカスタマイズ", function()
  local config = require("storyline.config")
  local prompt = require("storyline.ai.prompt")
  local ctx = { files = FILES, stat = "", diff = "" }

  after_each(function()
    config.setup({})
  end)

  it("analyze_extra が追加の指示として入る", function()
    config.setup({ prompts = { analyze_extra = "チャプター名は英語で書く" } })
    local p = prompt.build(ctx)
    assert.is_truthy(p:find("# 追加の指示", 1, true))
    assert.is_truthy(p:find("チャプター名は英語で書く", 1, true))
    -- JSON スキーマ指示は維持される
    assert.is_truthy(p:find('"chapters"', 1, true))
  end)

  it("ask_extra が質問プロンプトに入る", function()
    config.setup({ prompts = { ask_extra = "回答は箇条書きで" } })
    local p = prompt.build_question({
      story_title = "t",
      base_ref = "main",
      chapter = { title = "ch", files = {} },
      diff = "",
      question = "why?",
    })
    assert.is_truthy(p:find("回答は箇条書きで", 1, true))
  end)

  it("build_analyze / build_question で全体を差し替えられる", function()
    config.setup({
      prompts = {
        build_analyze = function(c)
          return "CUSTOM_ANALYZE:" .. #c.files
        end,
        build_question = function(a)
          return "CUSTOM_Q:" .. a.question
        end,
      },
    })
    assert.equals("CUSTOM_ANALYZE:3", prompt.build(ctx))
    assert.equals(
      "CUSTOM_Q:why?",
      prompt.build_question({ chapter = { files = {} }, diff = "", question = "why?" })
    )
  end)
end)

describe("sidebar のパス短縮", function()
  local sidebar = require("storyline.ui.sidebar")

  it("共通ディレクトリプレフィックスを求める", function()
    assert.equals(
      "apps/backend/src/services",
      sidebar.common_dir_prefix({
        "apps/backend/src/services/foo/a.ts",
        "apps/backend/src/services/bar/b.ts",
      })
    )
    -- 1ファイルなら親ディレクトリまで畳む
    assert.equals("apps/backend", sidebar.common_dir_prefix({ "apps/backend/a.ts" }))
    -- 共通部分がなければ空
    assert.equals("", sidebar.common_dir_prefix({ "apps/a.ts", "libs/b.ts" }))
    -- ルート直下ファイルを含む場合も空
    assert.equals("", sidebar.common_dir_prefix({ "README.md", "apps/a.ts" }))
  end)

  it("ディレクトリツリーを構築し単一子ディレクトリを連結する", function()
    local tree = sidebar.build_tree({
      "apps/backend/src/services/foo/a.ts",
      "apps/backend/src/services/foo/b.ts",
      "apps/backend/src/services/bar/c.ts",
      "apps/backend/src/worker/handlers/d.ts",
      "root.md",
    })
    -- ルート直下のファイル
    assert.equals(1, #tree.files)
    assert.equals("root.md", tree.files[1].name)
    -- apps/backend/src までは単一子の連鎖なので1ノードに連結される
    assert.equals(1, #tree.dirs)
    assert.equals("apps/backend/src", tree.dirs[1].name)
    -- その下は services と worker/handlers（後者も連結）に分岐
    local names = { tree.dirs[1].dirs[1].name, tree.dirs[1].dirs[2].name }
    assert.same({ "services", "worker/handlers" }, names)
    -- services の下は bar, foo（名前順）
    local services = tree.dirs[1].dirs[1]
    assert.same({ "bar", "foo" }, { services.dirs[1].name, services.dirs[2].name })
    assert.equals(2, #services.dirs[2].files)
  end)

  it("幅に収まらないパスを pathshorten で短縮する", function()
    assert.equals("short.ts", sidebar.shorten_path("short.ts", 30))
    local long = "services/meeting-task-reports/employee-analysis/prompts/turnover.prompt.ts"
    local shortened = sidebar.shorten_path(long, 40)
    assert.is_true(vim.fn.strdisplaywidth(shortened) <= 40)
    assert.is_truthy(shortened:match("turnover%.prompt%.ts$"))
    -- 極端に狭くてもファイル名の末尾は残る
    local tiny = sidebar.shorten_path(long, 12)
    assert.is_true(vim.fn.strdisplaywidth(tiny) <= 12)
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
