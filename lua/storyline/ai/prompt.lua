local config = require("storyline.config")

local M = {}

M.retry_suffix = [[

前回の出力は JSON として解釈できませんでした。
コードフェンス・前置き・補足説明を一切付けず、指定したスキーマの JSON オブジェクトのみを出力し直してください。]]

local function prompts_config()
  return config.options.prompts or {}
end

local ROLE_LABELS = { entry = "エントリポイント候補", test = "テスト" }

--- ファイル一覧の行に依存トレースの役割注釈を付ける
local function role_suffix(trace, path)
  local label = trace and trace.roles and ROLE_LABELS[trace.roles[path]]
  return label and ("（" .. label .. "）") or ""
end

--- 依存関係セクション（import する側 → される側）を parts に追記する
local function append_trace_edges(parts, trace)
  if not (trace and trace.edges and #trace.edges > 0) then
    return
  end
  table.insert(parts, "# 依存関係（静的解析。import する側 → される側）")
  local max_edges = 80
  for i, edge in ipairs(trace.edges) do
    if i > max_edges then
      table.insert(parts, string.format("…（他 %d 件）", #trace.edges - max_edges))
      break
    end
    table.insert(parts, string.format("- %s → %s", edge[1], edge[2]))
  end
  table.insert(parts, "")
end

--- ctx: {
---   files, stat, diff, pr?,
---   instruction?: string,          -- 組み替え指示（あれば優先して従う）
---   current_chapters?: { {title, files} }, -- 現在のチャプター構成
--- }
function M.build(ctx)
  local prompts = prompts_config()
  if prompts.build_analyze then
    return prompts.build_analyze(ctx)
  end

  local file_lines = {}
  for _, f in ipairs(ctx.files) do
    table.insert(
      file_lines,
      string.format("- %s (%s, +%d -%d)%s", f.path, f.status, f.added, f.deleted, role_suffix(ctx.trace, f.path))
    )
  end

  local intro = [[あなたはシニアエンジニアのコードレビューを支援する AI です。
以下は Pull Request の変更内容です。レビュアーが「物語を読むように」順番に理解できるよう、
変更ファイルを意味のある単位（チャプター）にグルーピングし、読むべき順に並べてください。]]
  if ctx.instruction and ctx.instruction ~= "" then
    intro = [[あなたはシニアエンジニアのコードレビューを支援する AI です。
以下は Pull Request の変更内容と、現在のチャプター構成です。
ユーザーの組み替え指示に従い、チャプターの分け方・順番・見出しを組み替え直してください。]]
  end

  local parts = {
    intro,
    "",
    [[出力は次のスキーマの JSON オブジェクトのみ。コードフェンスや説明文は一切付けないでください。

{
  "title": "PR 全体の一行要約",
  "chapters": [
    {
      "id": 1,
      "title": "チャプター名（例: 認証フローの土台）",
      "summary": "このチャプターで何がどう変わるかの2〜3文の説明",
      "review_points": ["レビュー時に注意して読むべき点（1〜4個）"],
      "files": ["変更ファイル一覧に含まれるパスのみ"]
    }
  ]
}

制約:
- files には下記「変更ファイル一覧」のパスをそのまま使い、全ファイルをいずれか1つのチャプターに割り当てる
- チャプターは変更を上流から辿れる順に並べる:
  「エントリポイント（上流）→ 呼び出される中核ロジック → 周辺（設定・ドキュメント）」。
  「依存関係」セクションがあれば、その呼び出しの流れに沿わせる
- テストコードは独立したチャプターにしない。対象の実装と同じチャプターに入れ、
  実装ファイルの直後に並べる（コロケーション）
- summary とチャプター名は日本語で書く]],
    "",
  }

  if ctx.instruction and ctx.instruction ~= "" then
    table.insert(parts, "# ユーザーからの組み替え指示")
    table.insert(parts, "次の指示を最優先で守り、チャプター構成を組み替えてください。")
    table.insert(parts, ctx.instruction)
    table.insert(parts, "")
  end

  if ctx.current_chapters and #ctx.current_chapters > 0 then
    table.insert(parts, "# 現在のチャプター構成")
    for i, ch in ipairs(ctx.current_chapters) do
      table.insert(parts, string.format("%d. %s", i, ch.title or ""))
      for _, path in ipairs(ch.files or {}) do
        table.insert(parts, "   - " .. path)
      end
    end
    table.insert(parts, "")
  end

  if prompts.analyze_extra and prompts.analyze_extra ~= "" then
    table.insert(parts, "# 追加の指示")
    table.insert(parts, prompts.analyze_extra)
    table.insert(parts, "")
  end

  append_trace_edges(parts, ctx.trace)

  if ctx.pr then
    table.insert(parts, "# PR タイトル")
    table.insert(parts, ctx.pr.title or "")
    table.insert(parts, "")
    table.insert(parts, "# PR 説明")
    table.insert(parts, ctx.pr.body or "")
    table.insert(parts, "")
  end

  vim.list_extend(parts, {
    "# 変更ファイル一覧",
    table.concat(file_lines, "\n"),
    "",
    "# diff --stat",
    ctx.stat,
    "",
    "# diff（ファイルごとに行数上限あり）",
    ctx.diff,
  })

  return table.concat(parts, "\n")
end

--- 読むモード事前調査: 候補パスから話題の切り口を列挙する
--- ctx: { topic = string, files = { {path} } }
function M.build_read_scout(ctx)
  local prompts = prompts_config()
  if prompts.build_read_scout then
    return prompts.build_read_scout(ctx)
  end

  local file_lines = {}
  for _, f in ipairs(ctx.files or {}) do
    table.insert(file_lines, "- " .. f.path)
  end

  local parts = {
    [[あなたはコードベースを案内するシニアエンジニアです。
ユーザーのトピックと候補ファイルのパス一覧だけを手がかりに、「何についての話がありそうか」を短く整理し、
ユーザーに興味のある切り口を選んでもらうための選択肢を作ってください。

出力は次のスキーマの JSON オブジェクトのみ。コードフェンスや説明文は一切付けないでください。

{
  "summary": "トピックについて候補を見た所感（1〜3文。ファイルパスの羅列はしない）",
  "question": "どれに興味がありますか？",
  "options": [
    {
      "label": "切り口の短い名前（例: レポートのエクスポート）",
      "keywords": ["パス絞り込み用の英数字トークン", "ExportReport"]
    }
  ]
}

制約:
- options は 2〜5 個。似た話はまとめ、明らかに別機能なら分ける
- 「もしかしてインポート？」のように近い別話題があってもよい
- keywords は候補パスに実際に出そうな識別子・ディレクトリ片を 1〜6 個
- summary / question / label は日本語
- 候補パスを summary に並べない]],
    "",
    "# トピック",
    ctx.topic or "",
    "",
    "# 候補ファイル一覧（パスのみ）",
    table.concat(file_lines, "\n"),
  }

  return table.concat(parts, "\n")
end

--- 読むモード: トピックに沿って読むべきファイルをチャプター化する
--- ctx: {
---   topic = string, focus? = string,
---   files = { {path, status, added, deleted} },
---   trace? = { edges = { {from, to} }, roles = { [path] = "entry"|"core"|"test" } },
--- }
function M.build_read(ctx)
  local prompts = prompts_config()
  if prompts.build_read then
    return prompts.build_read(ctx)
  end

  local file_lines = {}
  for _, f in ipairs(ctx.files or {}) do
    table.insert(file_lines, "- " .. f.path .. role_suffix(ctx.trace, f.path))
  end

  local parts = {
    [[あなたはシニアエンジニアのコードリーディングを支援する AI です。
ユーザーが指定したトピックについて「物語を読むように」順番に理解できるよう、
候補ファイルの中から読むべきものだけを選び、意味のある単位（チャプター）にグルーピングしてください。

出力は次のスキーマの JSON オブジェクトのみ。コードフェンスや説明文は一切付けないでください。

{
  "title": "トピックの一行要約",
  "chapters": [
    {
      "id": 1,
      "title": "チャプター名（例: エクスポート入口）",
      "summary": "このチャプターで何を理解するかの2〜3文",
      "review_points": ["読むときに見るべき点（1〜4個）"],
      "files": ["候補一覧に含まれるパスのみ"]
    }
  ]
}

制約:
- files には下記「候補ファイル一覧」のパスをそのまま使う（存在しないパスを作らない）
- トピックに無関係なファイルは入れない
- 「興味のある切り口」があればそれを最優先で絞り、無関係な別機能は入れない
- チャプターは「エントリポイント（上流）→ 呼び出される中核ロジック → 周辺」の順。
  「依存関係」セクションがあれば、その呼び出しの流れに沿って上から辿れるように並べる
- 依存関係で本筋と繋がらないファイルは外す
- 実装ファイルを主役にする。テストコードは対象の実装とセットのときだけ入れ、
  同じチャプターで実装ファイルの直後に並べる（コロケーション）。
  テストだけのチャプターや、テストが過半を占める構成にしない
- summary とチャプター名は日本語で書く
- 読む価値の高いファイルだけに絞る（目安: 全体で 5〜15 ファイル、最大でも 20）。
  候補を全部使う必要はまったくない。迷ったら外す。外したファイルは表示されない前提でよい
- migration.sql / prisma migrations / lock ファイルは、トピックが明示的にマイグレーションでない限り入れない]],
    "",
    "# トピック",
    ctx.topic or "",
    "",
  }

  append_trace_edges(parts, ctx.trace)

  if ctx.focus and ctx.focus ~= "" then
    table.insert(parts, "# 興味のある切り口")
    table.insert(parts, ctx.focus)
    table.insert(parts, "")
  end

  if prompts.read_extra and prompts.read_extra ~= "" then
    table.insert(parts, "# 追加の指示")
    table.insert(parts, prompts.read_extra)
    table.insert(parts, "")
  end

  vim.list_extend(parts, {
    "# 候補ファイル一覧",
    table.concat(file_lines, "\n"),
  })

  return table.concat(parts, "\n")
end

--- args: { story_title, base_ref, chapter = {title, summary, review_points, files}, diff, question }
--- JSON 指定はしない自由テキスト回答用のプロンプト
function M.build_question(args)
  local prompts = prompts_config()
  if prompts.build_question then
    return prompts.build_question(args)
  end

  local ch = args.chapter

  local parts = {
    [[あなたはコードレビューを支援する AI です。
以下の PR チャプターの変更内容を踏まえて質問に日本語で簡潔に答えてください。]],
    prompts.ask_extra and prompts.ask_extra ~= "" and (prompts.ask_extra .. "\n") or "",
    "# PR",
    args.story_title or "",
    ("base: %s"):format(args.base_ref or ""),
    "",
    "# チャプター",
    ch.title or "",
  }

  if ch.summary and ch.summary ~= "" then
    table.insert(parts, ch.summary)
  end

  if ch.review_points and #ch.review_points > 0 then
    table.insert(parts, "")
    table.insert(parts, "読むポイント:")
    for _, point in ipairs(ch.review_points) do
      table.insert(parts, "- " .. point)
    end
  end

  table.insert(parts, "")
  table.insert(parts, "対象ファイル:")
  for _, f in ipairs(ch.files or {}) do
    table.insert(parts, "- " .. f)
  end

  vim.list_extend(parts, {
    "",
    "# diff",
    args.diff,
    "",
    "# 質問",
    args.question,
  })

  return table.concat(parts, "\n")
end

return M
