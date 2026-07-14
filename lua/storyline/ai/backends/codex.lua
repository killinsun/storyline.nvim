return {
  name = "codex",
  label = "Codex CLI",
  available = function(cfg)
    return vim.fn.executable(cfg.cmd) == 1
  end,
  -- `codex exec -` は stdin からプロンプトを読む
  build_cmd = function(cfg)
    return vim.list_extend({ cfg.cmd }, cfg.args)
  end,
}
