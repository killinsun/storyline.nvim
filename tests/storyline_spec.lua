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
    assert.equals("CUSTOM_Q:why?", prompt.build_question({ chapter = { files = {} }, diff = "", question = "why?" }))
  end)

  it("instruction / current_chapters が組み替えプロンプトに入る", function()
    local p = prompt.build({
      files = FILES,
      stat = "",
      diff = "",
      instruction = "リクエストごとに resolver から辿れるように",
      current_chapters = {
        { title = "認証", files = { "src/auth/session.ts" } },
      },
    })
    assert.is_truthy(p:find("# ユーザーからの組み替え指示", 1, true))
    assert.is_truthy(p:find("リクエストごとに resolver から辿れるように", 1, true))
    assert.is_truthy(p:find("# 現在のチャプター構成", 1, true))
    assert.is_truthy(p:find("認証", 1, true))
    assert.is_truthy(p:find("src/auth/session.ts", 1, true))
    assert.is_truthy(p:find("組み替え直してください", 1, true))
  end)

  it("build_read にトピックと候補ファイルが入る", function()
    local p = prompt.build_read({
      topic = "CSVエクスポート機能について読むべきコードまとめて",
      files = FILES,
    })
    assert.is_truthy(p:find("# トピック", 1, true))
    assert.is_truthy(p:find("CSVエクスポート", 1, true))
    assert.is_truthy(p:find("# 候補ファイル一覧", 1, true))
    assert.is_truthy(p:find("src/auth/session.ts", 1, true))
    assert.is_truthy(p:find('"chapters"', 1, true))
  end)

  it("build_read に focus が入る", function()
    local p = prompt.build_read({
      topic = "CSVエクスポート",
      focus = "レポートのエクスポート",
      files = FILES,
    })
    assert.is_truthy(p:find("# 興味のある切り口", 1, true))
    assert.is_truthy(p:find("レポートのエクスポート", 1, true))
  end)

  it("build_read_scout にトピックと候補が入る", function()
    local p = prompt.build_read_scout({
      topic = "CSVエクスポート",
      files = FILES,
    })
    assert.is_truthy(p:find("# トピック", 1, true))
    assert.is_truthy(p:find("CSVエクスポート", 1, true))
    assert.is_truthy(p:find("# 候補ファイル一覧", 1, true))
    assert.is_truthy(p:find('"options"', 1, true))
    assert.is_truthy(p:find("切り口", 1, true))
  end)
end)

describe("schema.validate_scout", function()
  it("調査結果を正規化する", function()
    local scout = schema.validate_scout({
      summary = "CSVエクスポートはいくつか機能があるようです。",
      question = "どれに興味がありますか？",
      options = {
        { label = "レポートのエクスポート", keywords = { "ReportExport", "report" } },
        { label = "従業員一覧のエクスポート", keywords = { "employee" } },
      },
    })
    assert.is_not_nil(scout)
    assert.equals("CSVエクスポートはいくつか機能があるようです。", scout.summary)
    assert.equals(2, #scout.options)
    assert.same({ "ReportExport", "report" }, scout.options[1].keywords)
  end)

  it("不正な出力は nil", function()
    assert.is_nil(schema.validate_scout(nil))
    assert.is_nil(schema.validate_scout({ summary = "x", options = {} }))
    assert.is_nil(schema.validate_scout({ options = { { label = "A" } } }))
  end)
end)

describe("story.apply_chapters / toggle_opened", function()
  local story = require("storyline.story")

  after_each(function()
    story.clear()
  end)

  local function new_story()
    return story.new({
      repo_root = "/tmp/storyline-test-repo",
      base_ref = "main",
      merge_base = "mb123",
      head_sha = "hd456",
      files = FILES,
      title = "old title",
      chapters = {
        {
          id = 1,
          title = "A",
          summary = "",
          review_points = {},
          files = { "src/auth/session.ts" },
        },
        {
          id = 2,
          title = "B",
          summary = "",
          review_points = {},
          files = { "src/auth/middleware.ts", "docs/README.md" },
        },
      },
    })
  end

  it("opened を残し read と collapsed をクリアする", function()
    new_story()
    story.current.opened["src/auth/session.ts"] = true
    story.current.read[1] = true
    story.current.collapsed[2] = true
    story.current.current_chapter = 2

    local ok = story.apply_chapters("new title", {
      {
        id = 1,
        title = "X",
        summary = "",
        review_points = {},
        files = { "src/auth/session.ts", "src/auth/middleware.ts" },
      },
      {
        id = 2,
        title = "Y",
        summary = "",
        review_points = {},
        files = { "docs/README.md" },
      },
    })
    assert.is_true(ok)
    assert.equals("new title", story.current.title)
    assert.equals(2, #story.current.chapters)
    assert.equals("X", story.current.chapters[1].title)
    assert.is_true(story.current.opened["src/auth/session.ts"])
    assert.is_nil(story.current.read[1])
    assert.equals(1, story.current.current_chapter)
    assert.is_nil(story.current.collapsed[2])
  end)

  it("toggle_opened でファイル読了をトグルする", function()
    new_story()
    assert.is_true(story.toggle_opened("docs/README.md"))
    assert.is_true(story.current.opened["docs/README.md"])
    assert.is_true(story.toggle_opened("docs/README.md"))
    assert.is_nil(story.current.opened["docs/README.md"])
    assert.is_false(story.toggle_opened(nil))
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

  it("幅に収まらないパスはディレクトリだけ縮めファイル名は残す", function()
    assert.equals("short.ts", sidebar.shorten_path("short.ts", 30))
    local long = "services/meeting-task-reports/employee-analysis/prompts/turnover.prompt.ts"
    local shortened = sidebar.shorten_path(long, 40)
    assert.equals("turnover.prompt.ts", shortened:match("([^/]+)$"))
    assert.is_true(vim.fn.strdisplaywidth(shortened) <= 40)
    -- 極端に狭くてもファイル名は省略しない
    local tiny = sidebar.shorten_path(long, 12)
    assert.equals("turnover.prompt.ts", tiny)
  end)

  it("ファイル名単体は幅不足でも省略しない", function()
    local name = "employee-analysis-report-body.mapper.ts"
    assert.equals(name, sidebar.shorten_path(name, 10))
  end)
end)

describe("main.should_auto_split", function()
  local main = require("storyline.ui.main")

  it("threshold が 0 以下または nil なら false", function()
    local entry = { path = "a.ts", status = "M", added = 100, deleted = 100 }
    assert.is_false(main.should_auto_split(entry, 0))
    assert.is_false(main.should_auto_split(entry, -1))
    assert.is_false(main.should_auto_split(entry, nil))
  end)

  it("境界値で split 判定する", function()
    local entry = { path = "a.ts", status = "M", added = 50, deleted = 29 }
    assert.is_false(main.should_auto_split(entry, 80))
    entry.deleted = 30
    assert.is_true(main.should_auto_split(entry, 80))
  end)

  it("削除ファイルと nil entry は false", function()
    assert.is_false(main.should_auto_split({ path = "a.ts", status = "D", deleted = 100 }, 80))
    assert.is_false(main.should_auto_split(nil, 80))
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

describe("git.format_jst / format_commit_display", function()
  it("JST オフセット付き ISO を MM/DD HH:mm にする", function()
    assert.equals("07/16 06:12", git.format_jst("2026-07-16T06:12:11+09:00"))
  end)

  it("UTC の ISO を JST に変換する", function()
    assert.equals("07/16 06:12", git.format_jst("2026-07-15T21:12:11Z"))
  end)

  it("コミット行を short / 時刻 / PR / subject で並べる", function()
    assert.equals(
      "988c661  07/16 06:12  #128  プロンプト設定を追加",
      git.format_commit_display({
        short = "988c661",
        when_jst = "07/16 06:12",
        pr = 128,
        subject = "プロンプト設定を追加",
      })
    )
    assert.equals(
      "c78a057  07/15 12:29        プレビューキー変更",
      git.format_commit_display({
        short = "c78a057",
        when_jst = "07/15 12:29",
        subject = "プレビューキー変更",
      })
    )
  end)
end)

describe("git.refine_read_candidates", function()
  local sample = {
    "apps/api/schema.graphql",
    "apps/api/resolver.ts",
    "apps/worker/handler.ts",
    "db/migrations/001.sql",
    "docs/README.md",
  }

  it("除外で該当パスを落とす", function()
    local out = git.refine_read_candidates(sample, "migration 除外")
    assert.same({
      "apps/api/schema.graphql",
      "apps/api/resolver.ts",
      "apps/worker/handler.ts",
      "docs/README.md",
    }, out)
  end)

  it("だけ / のみで該当だけ残す", function()
    local out = git.refine_read_candidates(sample, "graphql だけ")
    assert.same({ "apps/api/schema.graphql" }, out)
  end)

  it("配下でプレフィックス配下だけ残す", function()
    local out = git.refine_read_candidates(sample, "apps/worker 配下")
    assert.same({ "apps/worker/handler.ts" }, out)
  end)

  it("キーワードなしは含むパスだけ残す", function()
    local out = git.refine_read_candidates(sample, "api")
    assert.same({
      "apps/api/schema.graphql",
      "apps/api/resolver.ts",
    }, out)
  end)

  it("空指示はそのまま返す", function()
    assert.same(sample, git.refine_read_candidates(sample, ""))
    assert.same(sample, git.refine_read_candidates(sample, "   "))
  end)
end)

describe("persist key (read mode)", function()
  it("merge_base が nil でも save/load が落ちない", function()
    local persist = require("storyline.persist")
    local data = {
      mode = "read",
      topic = "CSV export",
      repo_root = "/tmp/storyline-read-test",
      merge_base = nil,
      head_sha = "deadbeef",
      read = {},
      opened = { ["a.ts"] = true },
      current_chapter = 1,
    }
    assert.is_true(pcall(persist.save, data))
    local loaded = persist.load(data)
    -- ファイルが書けていれば opened が復元される（書けない環境でも nil でよい）
    if loaded then
      assert.is_true(loaded.opened["a.ts"])
    end
  end)
end)
