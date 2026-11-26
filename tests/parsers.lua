local ok, err = xpcall(function()
  local parsers = require('neotest-cmake.parsers')
  local function check(text)
    local results = parsers.results(text)
    assert(#results == 3, vim.inspect(results))
    for i, status in ipairs({ 'passed', 'failed', 'skipped' }) do
      assert(results[i].status == status, vim.inspect(results[i]))
      assert(not results[i].output:find('\27', 1, true), 'raw color in result')
      assert(not results[i].output:find('[NON-XML-CHAR-', 1, true), 'CTest color in result')
    end
    assert(results[1].key == 'Basic.Pass' and results[2].key == 'Basic.Fail'
      and results[3].key == 'Basic.Skip', 'color corrupted test names')
  end
  local run = vim.system({ './build/fixture/cases', '--gtest_color=yes', '--gtest_filter=Basic.*' },
    { text = true }):wait()
  assert(run.code == 1 and run.stdout:find('\27[', 1, true), 'fixture must produce colored output')
  check(run.stdout)
  check((run.stdout:gsub('\27', '[NON-XML-CHAR-0x1B]')))
  local listing = '\27[32mBasic.\27[m\n  \27[32mPass\27[m\n'
  assert(parsers.gtest_list(listing)[1].key == 'Basic.Pass', 'colored discovery failed')
  local report = vim.fn.tempname() .. '.xml'
  local result = vim.system({ 'ctest', '--test-dir', 'build/fixture', '--output-junit', report,
    '-R', 'discovered.*Basic' }, { text = true, env = { GTEST_COLOR = 'yes' } }):wait()
  local file = assert(io.open(report))
  local xml = file:read('*a')
  file:close()
  os.remove(report)
  assert(result.code ~= 0 and xml:find('[NON-XML-CHAR-0x1B]', 1, true), 'expected colored CTest report')
  local seen = {}
  for _, row in ipairs(parsers.junit(xml)) do
    assert(not row.output:find('[NON-XML-CHAR-0x1B]', 1, true), 'color leaked from JUnit')
    for _, case in ipairs(parsers.results(row.output)) do seen[case.key] = case.status end
  end
  assert(seen['Basic.Pass'] == 'passed' and seen['Basic.Fail'] == 'failed'
    and seen['Basic.Skip'] == 'skipped', vim.inspect(seen))
  print('All colored GoogleTest parser checks passed')
end, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
