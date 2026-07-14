return {
  name = "cursor",
  label = "Cursor Agent",
  available = function(cfg)
    return vim.fn.executable(cfg.cmd) == 1
  end,
  build_cmd = function(cfg)
    return vim.list_extend({ cfg.cmd }, cfg.args)
  end,
}
