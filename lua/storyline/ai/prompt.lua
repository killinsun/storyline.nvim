local M = {}

M.retry_suffix = [[

前回の出力は JSON として解釈できませんでした。
コードフェンス・前置き・補足説明を一切付けず、指定したスキーマの JSON オブジェクトのみを出力し直してください。]]

--- ctx: { files = { {path, status, added, deleted} }, stat = string, diff = string, pr?: {title, body} }
function M.build(ctx)
  local file_lines = {}
  for _, f in ipairs(ctx.files) do
    table.insert(file_lines, string.format("- %s (%s, +%d -%d)", f.path, f.status, f.added, f.deleted))
  end

  local parts = {
    [[あなたはシニアエンジニアのコードレビューを支援する AI です。
以下は Pull Request の変更内容です。レビュアーが「物語を読むように」順番に理解できるよう、
変更ファイルを意味のある単位（チャプター）にグルーピングし、読むべき順に並べてください。

出力は次のスキーマの JSON オブジェクトのみ。コードフェンスや説明文は一切付けないでください。

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
- チャプターは「土台・前提 → 中心となる変更 → 周辺（テスト・設定・ドキュメント）」のように読み進めやすい順に並べる
- summary とチャプター名は日本語で書く]],
    "",
  }

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

return M
