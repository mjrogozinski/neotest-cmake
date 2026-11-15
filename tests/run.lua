require('nio').run(function()
  require('nio').scheduler()
  local ok, err = xpcall(function()
    local root = vim.fn.getcwd() .. '/tests/fixture'
    local adapter = require('neotest-cmake')({ root = root, build_dir = '../../build/fixture' })
    local tree = assert(adapter.discover_positions(root .. '/cases.cpp'))
    local count = 0
    for _, node in tree:iter_nodes() do if node:data().type == 'test' then count = count + 1 end end
    assert(count == 16, 'expected sixteen concrete cases, got ' .. count)
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
      ['Basic.DISABLED_Off'] = 'skipped', ['Numbers/Values.Positive/0'] = 'passed', ['Numbers/Values.Positive/1'] = 'passed',
      ['Named/Values.Positive/Three'] = 'passed', ['Typed/0.Size'] = 'passed', ['Typed/1.Size'] = 'passed',
      ['Instances/TypeParameters/0.Size'] = 'passed', ['Instances/TypeParameters/1.Size'] = 'passed',
      ['Numbers/Values.Mixed/0'] = 'passed', ['Numbers/Values.Mixed/1'] = 'skipped',
      ['Named/Values.Mixed/Three'] = 'failed', ['Values.Positive/0'] = 'passed', ['Values.Mixed/0'] = 'passed' }
    for name, status in pairs(expected) do
      local id = root .. '/cases.cpp::' .. name
      assert(results[id] and results[id].status == status, name .. ': ' .. vim.inspect(results[id]))
    end
    local only = tree:get_key(root .. '/cases.cpp::Basic.Pass')
    local single = run(only)
    assert(vim.tbl_count(single) == 1 and single[only:data().id].status == 'passed')
    local function concrete(selected_tree, path, name)
      local node = assert(selected_tree:get_key(root .. '/' .. path .. '::' .. name), name)
      assert(node:data().name == name, 'display must use exact GoogleTest name')
      local results, spec = run(node)
      assert(vim.tbl_count(results) == 1 and results[node:data().id].status == 'passed', name)
      if spec.context.direct then
        assert(spec.command[3] == '--gtest_filter=' .. name, 'direct selection ran sibling parameters')
      else
        assert(vim.tbl_count(spec.context.mappings) == 1, 'CTest selection ran sibling parameters')
      end
    end
    for _, name in ipairs({ 'Numbers/Values.Positive/1', 'Named/Values.Positive/Three',
      'Typed/1.Size', 'Instances/TypeParameters/1.Size', 'Values.Positive/0' }) do concrete(tree, 'cases.cpp', name) end
    local debug_node = tree:get_key(root .. '/cases.cpp::Numbers/Values.Positive/1')
    local debug_spec = adapter.build_spec({ tree = debug_node, strategy = 'dap' })
    assert(debug_spec.strategy.type == 'codelldb' and debug_spec.strategy.request == 'launch')
    assert(vim.tbl_count(debug_spec.context.mappings) == 1)
    assert(debug_spec.strategy.args[#debug_spec.strategy.args] == '--gtest_filter=Numbers/Values.Positive/1')
    local debug_run = vim.system(debug_spec.command, { cwd = debug_spec.cwd, env = debug_spec.env, text = true }):wait()
    assert(debug_run.code == 0 and debug_run.stdout:find('1 test from 1 test suite ran', 1, true))
    local values = tree:get_key(root .. '/cases.cpp::Values.Positive')
    assert(values:data().type == 'namespace' and #values:children() == 4)
    assert(require('neotest.lib').positions.nearest(tree, values:data().range[1]):data().id == values:data().id,
      'nearest source action must select all parameters')
    local grouped = adapter.discover_positions(root .. '/grouped.cpp')
    local group_results, spec = run(grouped)
    assert(group_results[root .. '/grouped.cpp::Group.Environment'].status == 'passed', 'fixture/environment not preserved')
    assert(group_results[root .. '/grouped.cpp::Group.Failure'].status == 'failed')
    local can_debug, debug_error = pcall(adapter.build_spec, { tree = grouped, strategy = 'dap' })
    assert(not can_debug and tostring(debug_error):find('CTest fixtures', 1, true), tostring(debug_error))
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
      ['Numbers/DirectValues.Positive/0'] = 'passed', ['Numbers/DirectValues.Positive/1'] = 'passed',
      ['Named/DirectValues.Positive/Three'] = 'passed', ['DirectTyped/0.Size'] = 'passed', ['DirectTyped/1.Size'] = 'passed',
      ['Instances/DirectTypeParameters/0.Size'] = 'passed', ['Instances/DirectTypeParameters/1.Size'] = 'passed',
      ['Numbers/DirectValues.Mixed/0'] = 'passed', ['Numbers/DirectValues.Mixed/1'] = 'skipped',
      ['Named/DirectValues.Mixed/Three'] = 'failed', ['DirectValues.Positive/0'] = 'passed', ['DirectValues.Mixed/0'] = 'passed' }) do
      assert(direct[root .. '/unregistered.cpp::' .. name].status == status, name .. ' direct result mismatch')
    end
    for _, name in ipairs({ 'Numbers/DirectValues.Positive/1', 'Named/DirectValues.Positive/Three',
      'DirectTyped/1.Size', 'Instances/DirectTypeParameters/1.Size', 'DirectValues.Positive/0' }) do concrete(direct_tree, 'unregistered.cpp', name) end
    local direct_debug = adapter.build_spec({
      tree = direct_tree:get_key(root .. '/unregistered.cpp::Instances/DirectTypeParameters/1.Size'), strategy = 'dap' })
    assert(direct_debug.strategy.args[2] == '--gtest_filter=Instances/DirectTypeParameters/1.Size')
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
    assert(vim.tbl_count(mixed_results) == 33, 'mixed run lost results')
    assert(mixed_results[root .. '/cases.cpp::Basic.Pass'].status == 'passed')
    assert(mixed_results[root .. '/unregistered.cpp::Direct.Pass'].status == 'passed')
    assert(mixed_results[root .. '/second.cpp::SecondBinary.Pass'].status == 'passed')
    -- The external builder can use a preset's binary directory instead of the
    -- adapter's default. Discovery must hand that exact context to future runs.
    adapter({ build_dir = 'deliberately-wrong-build-directory' })
    local found = adapter.discover({ root = root, build_dir = '../../build/fixture' })
    assert(found.binaries == 5, 'discovery did not group registrations by executable: ' .. vim.inspect(found))
    assert(found.cases == 38, 'incorrect concrete case count: ' .. vim.inspect(found))
    local after_build, after_spec = run(nearest)
    assert(after_build[nearest:data().id].status == 'passed')
    assert(after_spec.cwd == vim.fs.normalize(root .. '/../../build/fixture'), 'run ignored discovered build directory')
    -- A broken unrelated target must not block a selected file. Selecting that
    -- broken target must stop before producing any runnable stale-test spec.
    local broken_path = root .. '/unregistered.cpp'
    local original = assert(detection.read(broken_path))
    local function write(text)
      local file = assert(io.open(broken_path, 'w')); file:write(text); file:close()
    end
    local checked, reason = xpcall(function()
      write(original .. '\n#error intentional_build_failure\n')
      local unrelated = run(only)
      assert(unrelated[only:data().id].status == 'passed', 'built an unrelated broken binary')
      local blocked = adapter.build_spec({ tree = nearest, strategy = 'integrated' })
      assert(blocked.context.build_failure, 'failed build produced a runnable test spec')
      assert(#blocked.command == 0 and type(blocked.strategy) == 'function', 'stale binary could run')
      local qf = vim.fn.getqflist({ items = 0, title = 0, winid = 0 })
      assert(qf.title == 'CMake build failed; tests not run' and qf.winid > 0, 'quickfix did not open')
      local diagnostic
      for _, item in ipairs(qf.items) do
        if vim.api.nvim_buf_get_name(item.bufnr) == broken_path and item.text:find('intentional_build_failure', 1, true) then
          diagnostic = item
        end
      end
      assert(diagnostic and diagnostic.lnum > 0 and diagnostic.type == 'E', 'missing clickable compiler error')
      local instance = blocked.strategy()
      local skipped = adapter.results(blocked, { code = instance.result(), output = instance.output() })
      assert(skipped[nearest:data().id].status == 'skipped', 'blocked tests must not report a stale pass')
      write(original .. '\nINSTANTIATE_TEST_SUITE_P(Added, DirectValues, testing::Values(4));\n')
      adapter.prepare(nearest)
      assert(#vim.fn.getqflist() == 0, 'successful rebuild left stale compiler diagnostics')
      local updated = assert(adapter.discover_positions(broken_path))
      concrete(updated, 'unregistered.cpp', 'Added/DirectValues.Positive/0')
    end, debug.traceback)
    write(original)
    adapter.prepare(nearest)
    assert(checked, reason)
    print('All adapter integration checks passed')
  end, debug.traceback)
  require('nio').scheduler()
  if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
end)
