local M = {}

local function executable(name, minimum)
  if vim.fn.executable(name) ~= 1 then
    vim.health.error(name .. ' is not executable', { 'Install ' .. name .. ' or configure its executable path.' })
    return
  end
  local result = vim.system({ name, '--version' }, { text = true, timeout = 5000 }):wait()
  local major, minor = (result.stdout or ''):match('version%s+(%d+)%.(%d+)')
  if result.code ~= 0 or not major then
    vim.health.warn('Could not read ' .. name .. ' version')
  elseif tonumber(major) < minimum[1] or (tonumber(major) == minimum[1] and tonumber(minor) < minimum[2]) then
    vim.health.error(name .. ' requires version ' .. table.concat(minimum, '.') .. '+')
  else
    vim.health.ok(name .. ' ' .. major .. '.' .. minor)
  end
end

function M.check()
  vim.health.start('neotest-cmake')
  if vim.fn.has('nvim-0.10') == 1 then
    vim.health.ok('Neovim 0.10+')
  else
    vim.health.error('Neovim 0.10+ is required')
  end
  if vim.fn.has('win32') == 1 then
    vim.health.warn('Native Windows paths are not supported; use a Unix environment.')
  end
  for _, module in ipairs({ 'neotest', 'nio', 'plenary' }) do
    if
      package.loaded[module]
      or #vim.api.nvim_get_runtime_file('lua/' .. module .. '/init.lua', false) > 0
      or #vim.api.nvim_get_runtime_file('lua/' .. module .. '.lua', false) > 0
    then
      vim.health.ok(module .. ' is available')
    else
      vim.health.error('Missing Lua dependency: ' .. module)
    end
  end
  local options = require('neotest-cmake.project').options()
  executable(options.cmake or 'cmake', { 3, 21 })
  executable(options.ctest or 'ctest', { 3, 21 })
  local ok, parser = pcall(vim.treesitter.get_string_parser, 'int main() {}', 'cpp')
  if ok then
    local parsed, err = pcall(parser.parse, parser)
    if parsed then
      vim.health.ok('C++ Tree-sitter parser loads and parses')
    else
      vim.health.error('C++ parser could not parse: ' .. tostring(err))
    end
  else
    vim.health.error(
      'C++ Tree-sitter parser is unavailable',
      { 'Install a cpp parser compatible with this Neovim version.' }
    )
  end
  vim.health.info('GoogleTest, the compiler, and build tools are supplied by your project environment.')
  vim.health.info('Overseer and nvim-dap are optional. No builds or test binaries are run by this check.')
end

return M
