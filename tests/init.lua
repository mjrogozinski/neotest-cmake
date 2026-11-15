vim.opt.rtp:prepend(vim.fn.getcwd())
local plugins = vim.env.NEOTEST_DEPS or (vim.fn.expand('~') .. '/.local/share/nvim/lazy')
for _, name in ipairs({ 'neotest', 'nvim-nio', 'plenary.nvim' }) do
  vim.opt.rtp:append(plugins .. '/' .. name)
end
-- Override for CI or a nonstandard parser installation.
if vim.env.CPP_PARSER_DIR then vim.opt.rtp:append(vim.env.CPP_PARSER_DIR) end
