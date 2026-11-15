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
    local detection = require('neotest-cmake.discovery')
    for _, signature in ipairs({
      '/nix/store/example-gtest/lib/libgtest_main.1.18.0.dylib',
      'libgtest.so.1.14.0', 'gtest_main.dll',
    }) do
      local binary = vim.fn.tempname()
      local file = assert(io.open(binary, 'wb'))
      -- Straddle a scan chunk to exercise the overlap used by detection.
      file:write(string.rep('\0', 65530) .. signature .. '\0')
      file:close()
      assert(detection.framework({ binary }, {}, root) == 'gtest', 'missed shared library signature: ' .. signature)
      assert(detection.framework({ binary }, { [binary] = 'ctest' }, root) == nil, 'framework override ignored')
      os.remove(binary)
    end
    local function run(selected)
      local built = adapter.build_spec({ tree = selected, strategy = 'integrated' })
      local specs = built.command and { built } or built
      local results = {}
      for _, spec in ipairs(specs) do
        local r = vim.system(spec.command, { cwd = spec.cwd, text = true }):wait()
        local output = vim.fn.tempname()
        vim.fn.writefile(vim.split((r.stdout or '') .. (r.stderr or ''), '\n'), output)
        for id, result in pairs(adapter.results(spec, { code = r.code, output = output })) do
          assert(not results[id], 'multiple specs reported ' .. id)
          results[id] = result
        end
        os.remove(output)
      end
      return results, built
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
    local direct_tree = adapter.discover_positions(root .. '/unregistered.cpp')
    local direct, direct_spec = run(direct_tree)
    assert(direct_spec.context.direct, 'unregistered target must run directly')
    for name, status in pairs({ ['Direct.Pass'] = 'passed', ['Direct.Fail'] = 'failed',
      ['Direct.Skip'] = 'skipped', ['Direct.DISABLED_Off'] = 'skipped',
      ['DirectValues.Positive'] = 'passed', ['DirectTyped.Size'] = 'passed' }) do
      assert(direct[root .. '/unregistered.cpp::' .. name].status == status, name .. ' direct result mismatch')
    end
    local nearest = direct_tree:get_key(root .. '/unregistered.cpp::Direct.Pass')
    local nearest_results, nearest_spec = run(nearest)
    assert(vim.tbl_count(nearest_results) == 1 and nearest_results[nearest:data().id].status == 'passed')
    assert(nearest_spec.command[3] == '--gtest_filter=Direct.Pass', 'direct run included unrelated failing case')
    local second = adapter.discover_positions(root .. '/second.cpp')
    local mixed = require('neotest.types').Tree.from_list({
      { id = root, path = root, name = 'fixture', type = 'dir' },
      tree:to_list(), direct_tree:to_list(), second:to_list(),
    }, function(pos) return pos.id end)
    local mixed_results, mixed_specs = run(mixed)
    assert(#mixed_specs.context.runs == 3, 'expected one CTest batch and two direct binaries')
    assert(not mixed_specs.context.runs[1].context.direct, 'registered executables must retain CTest semantics')
    assert(vim.tbl_count(mixed_results) == 13, 'mixed run lost results')
    assert(mixed_results[root .. '/cases.cpp::Basic.Pass'].status == 'passed')
    assert(mixed_results[root .. '/unregistered.cpp::Direct.Pass'].status == 'passed')
    assert(mixed_results[root .. '/second.cpp::SecondBinary.Pass'].status == 'passed')
    -- The external builder can use a preset's binary directory instead of the
    -- adapter's default. Discovery must hand that exact context to future runs.
    adapter({ build_dir = 'deliberately-wrong-build-directory' })
    local found = adapter.discover({ root = root, build_dir = '../../build/fixture' })
    assert(found.binaries == 5, 'discovery did not group registrations by executable: ' .. vim.inspect(found))
    assert(found.cases == 22, 'incorrect concrete case count: ' .. vim.inspect(found))
    local after_build, after_spec = run(nearest)
    assert(after_build[nearest:data().id].status == 'passed')
    assert(after_spec.cwd == vim.fs.normalize(root .. '/../../build/fixture'), 'run ignored discovered build directory')
    print('All adapter integration checks passed')
  end, debug.traceback)
  require('nio').scheduler()
  if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
end)
