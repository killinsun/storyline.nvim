-- headless テスト用の最小構成
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:append(root)

-- plenary / gitsigns は lazy.nvim のインストール先から借りる
local lazy_root = vim.fn.stdpath("data") .. "/lazy"
for _, name in ipairs({ "plenary.nvim", "gitsigns.nvim" }) do
  local path = lazy_root .. "/" .. name
  if vim.uv.fs_stat(path) then
    vim.opt.runtimepath:append(path)
  end
end
