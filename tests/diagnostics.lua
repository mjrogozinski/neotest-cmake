require('nio').run(function()
  local ok, err = xpcall(function()
    require('nio').scheduler()
    local root = vim.fn.getcwd() .. '/tests/fixture'
    local build = vim.fn.getcwd() .. '/build/fixture'
    local diagnostics = require('neotest-cmake.diagnostics')
    local failure = diagnostics.report(root, build, 'build', {
      code = 1,
      stdout = '\27[31m../../tests/fixture/cases.cpp:9:4: error: example compiler failure\27[0m\n',
      stderr = '',
    })
    local items = vim.fn.getqflist()
    assert(#items == 1 and items[1].type == 'E' and items[1].lnum == 9 and items[1].col == 4, vim.inspect(items))
    assert(vim.api.nvim_buf_get_name(items[1].bufnr) == root .. '/cases.cpp', 'relative compiler path used editor cwd')
    assert(items[1].text == 'example compiler failure', 'ANSI color leaked into diagnostic')
    assert(vim.fn.filereadable(failure.output) == 1, 'full build log was lost')
    diagnostics.report(
      root,
      build,
      'configure',
      { code = 1, stderr = 'CMake Error at CMakeLists.txt:3 (find_package):\n  Required dependency not found\n\n' }
    )
    items = vim.fn.getqflist()
    assert(#items == 1 and items[1].lnum == 3, vim.inspect(items))
    assert(items[1].text:find('Required dependency not found', 1, true), vim.inspect(items))
    diagnostics.report(root, build, 'build', { code = 1, stderr = 'ld: undefined symbol example\n' })
    items = vim.fn.getqflist()
    assert(#items > 0 and items[1].text:find('undefined symbol example', 1, true), vim.inspect(items))
    diagnostics.clear(root, build)
    assert(#vim.fn.getqflist() == 0)
    vim.fn.setqflist({}, ' ', { title = 'User search results', items = { { text = 'keep this' } } })
    diagnostics.clear(root, build)
    assert(vim.fn.getqflist({ title = 0 }).title == 'User search results', 'cleared an unrelated list')
    io.stdout:write('Build diagnostic quickfix checks passed\n')
  end, debug.traceback)
  require('nio').scheduler()
  if not ok then
    io.stderr:write(err .. '\n')
    vim.cmd('cquit 1')
  else
    vim.cmd('qa!')
  end
end)
