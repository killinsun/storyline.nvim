return {
  name = "claude",
  label = "Claude Code",
  available = function(cfg)
    return vim.fn.executable(cfg.cmd) == 1
  end,
  -- プロンプトは stdin で渡す
  build_cmd = function(cfg)
    return vim.list_extend({ cfg.cmd }, cfg.args)
  end,
}
