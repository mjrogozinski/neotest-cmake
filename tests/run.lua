require('nio').run(function()
  require('nio').scheduler()
  local ok, err = xpcall(function()
    local root = vim.fn.getcwd() .. '/tests/fixture'
    local adapter = require('neotest-cmake')({ root = root, build_dir = '../../build/fixture' })
    local tree = assert(adapter.discover_positions(root .. '/cases.cpp'))
    local count = 0
    for _, node in tree:iter_nodes() do if node:data().type == 'test' then count = count + 1 end end
    assert(count == 6, 'expected six real macro definitions, got ' .. count)
    assert(adapter.is_test_file(root .. '/cases.cpp'))
    local function run(selected)
      local spec = adapter.build_spec({ tree = selected, strategy = 'integrated' })
      local r = vim.system(spec.command, { cwd = spec.cwd, text = true }):wait()
      local output = vim.fn.tempname()
      vim.fn.writefile(vim.split((r.stdout or '') .. (r.stderr or ''), '\n'), output)
      local results = adapter.results(spec, { code = r.code, output = output })
      os.remove(output)
      return results, spec
    end
    local results = run(tree)
    local expected = { ['Basic.Pass'] = 'passed', ['Basic.Fail'] = 'failed', ['Basic.Skip'] = 'skipped',
      ['Basic.DISABLED_Off'] = 'skipped', ['Values.Positive'] = 'passed', ['Typed.Size'] = 'passed' }
    for name, status in pairs(expected) do
      local id = root .. '/cases.cpp::' .. name
      assert(results[id] and results[id].status == status, name .. ': ' .. vim.inspect(results[id]))
    end
    local only = tree:get_key(root .. '/cases.cpp::Basic.Pass')
    local single = run(only)
    assert(vim.tbl_count(single) == 1 and single[only:data().id].status == 'passed')
    local grouped = adapter.discover_positions(root .. '/grouped.cpp')
    local group_results, spec = run(grouped)
    assert(group_results[root .. '/grouped.cpp::Group.Environment'].status == 'passed', 'fixture/environment not preserved')
    assert(group_results[root .. '/grouped.cpp::Group.Failure'].status == 'failed')
    local nearest_grouped = run(grouped:get_key(root .. '/grouped.cpp::Group.Environment'))
    assert(vim.tbl_count(nearest_grouped) == 1)
    assert(nearest_grouped[root .. '/grouped.cpp::Group.Environment'].status == 'passed')
    assert(not vim.uv.fs_stat(vim.fn.getcwd() .. '/build/fixture/prepared'), 'fixture cleanup did not run')
    local missing = adapter.results(spec, { code = 1, output = '/tmp/absent' })
    assert(missing[root .. '/grouped.cpp::Group.Environment'].status == 'failed')
    local policy = run(adapter.discover_positions(root .. '/policy.cpp'))
    assert(policy[root .. '/policy.cpp::Policy.ExpectedFailure'].status == 'passed')
    assert(policy[root .. '/policy.cpp::Policy.Timeout'].status == 'failed')
    assert(policy[root .. '/policy.cpp::Policy.SkipRule'].status == 'skipped')
    print('All adapter integration checks passed')
  end, debug.traceback)
  require('nio').scheduler()
  if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
end)
