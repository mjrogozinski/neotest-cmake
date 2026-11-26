local project = require('neotest-cmake.project')
local health = require('neotest-cmake.health')
local saved_health, saved_system = vim.health, vim.system
local saved_executable, saved_parser = vim.fn.executable, vim.treesitter.get_string_parser
local saved_options = project.options()
local messages, launches = {}, {}
local missing, version, parser_missing = false, '3.21.0', false
local ok, err = xpcall(function()
  local reports = {}
  for _, level in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
    reports[level] = function(message)
      messages[#messages + 1] = { level, message }
    end
  end
  vim.health = reports
  vim.fn.executable = function()
    return missing and 0 or 1
  end
  vim.system = function(command, options)
    assert(#command == 2 and command[2] == '--version', 'health launched a build or test')
    assert(options.timeout == 5000, 'version probes need bounded execution')
    launches[#launches + 1] = command[1]
    return {
      wait = function()
        return { code = 0, stdout = 'cmake version ' .. version }
      end,
    }
  end
  vim.treesitter.get_string_parser = function()
    assert(not parser_missing, 'missing parser')
    return {
      parse = function()
        return {}
      end,
    }
  end
  local function contains(level, text)
    for _, message in ipairs(messages) do
      if message[1] == level and message[2]:find(text, 1, true) then
        return true
      end
    end
    return false
  end
  project.configure({ cmake = '/custom/cmake', ctest = '/custom/ctest' })
  health.check()
  assert(vim.deep_equal(launches, { '/custom/cmake', '/custom/ctest' }), 'ignored executable overrides')
  assert(contains('ok', 'C++ Tree-sitter parser'))
  assert(not contains('error', 'Missing Lua dependency'), 'installed dependencies were not found')
  assert(project.options().cmake == '/custom/cmake', 'health changed configuration')
  messages, launches, missing, parser_missing = {}, {}, true, true
  health.check()
  assert(#launches == 0 and contains('error', 'not executable'))
  assert(contains('error', 'parser is unavailable'))
  messages, missing, version, parser_missing = {}, false, '3.20.9', false
  health.check()
  assert(contains('error', 'requires version 3.21+'))
  messages, version = {}, '4.0.0'
  health.check()
  assert(contains('ok', '/custom/cmake 4.0'))
end, debug.traceback)
vim.health, vim.system = saved_health, saved_system
vim.fn.executable, vim.treesitter.get_string_parser = saved_executable, saved_parser
project.configure(saved_options)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
end
io.stdout:write('Health checks passed: configured paths, minimum versions, missing tools/parser, bounded probes\n')
vim.cmd('qa!')
