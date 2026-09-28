return {
  name = "cursor",
  label = "Cursor Agent",
  available = function(cfg)
    return vim.fn.executable(cfg.cmd) == 1
  end,
  build_cmd = function(cfg)
    local cmd = vim.list_extend({ cfg.cmd }, cfg.args or {})
    local model = require("storyline.config").options.model
    if model and model ~= "" then
      cmd[#cmd + 1] = "--model"
      cmd[#cmd + 1] = model
    end
    return cmd
  end,
}
