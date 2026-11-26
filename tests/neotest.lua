local write_fixture = dofile('tests/helpers.lua').write
-- Real Neotest client, runner and summary; no mocked execution or UI rendering.
require('nio').run(function()
  local nio = require('nio')
  nio.scheduler()
  local ok, err = xpcall(function()
    local root = vim.fn.getcwd() .. '/tests/fixture'
    root = assert(vim.uv.fs_realpath(root))
    local path = root .. '/cases.cpp'
    local build = '../../build/fixture'
    local adapter = require('neotest-cmake')({ root = root, build_dir = build })
    local neotest, client = require('neotest'), nil
    local concrete, run_count, runs = {}, 0, 0
    -- The test uses the main process parser, including CPP_PARSER_DIR.
    require('neotest.lib').subprocess.init = function() end
    neotest.setup({
      adapters = { adapter },
      discovery = { enabled = false },
      status = { signs = true, virtual_text = true },
      consumers = {
        cmake = require('neotest-cmake.consumer'),
        check = function(c)
          client = c
          c.listeners.run = function()
            runs = runs + 1
          end
          c.listeners.results = function(_, results, partial)
            if not partial then
              concrete, run_count = results, run_count + 1
            end
          end
          return {}
        end,
      },
    })
    vim.cmd.edit(path)
    local expected = {
      'Basic.Pass',
      'Basic.Fail',
      'Basic.Skip',
      'Basic.DISABLED_Off',
      'Numbers/Values.Positive/0',
      'Numbers/Values.Positive/1',
      'Named/Values.Positive/Three',
      'Numbers/Values.Mixed/0',
      'Numbers/Values.Mixed/1',
      'Named/Values.Mixed/Three',
      'Values.Positive/0',
      'Values.Mixed/0',
      'Typed/0.Size',
      'Typed/1.Size',
      'Instances/TypeParameters/0.Size',
      'Instances/TypeParameters/1.Size',
    }
    local function invoke(label, action, expected_builds)
      local previous, system, builds = run_count, vim.system, 0
      vim.system = function(command, ...)
        if vim.tbl_contains(command, '--build') then
          builds = builds + 1
        end
        return system(command, ...)
      end
      local ok, reason = pcall(action)
      if not ok then
        vim.system = system
        error(reason)
      end
      for _ = 1, 3000 do
        if run_count > previous then
          break
        end
        nio.sleep(20)
      end
      vim.system = system
      assert(run_count > previous, label .. ' did not finish')
      assert(builds == (expected_builds or 1), label .. ': unexpected build count ' .. builds)
    end
    do
      -- Plain Neotest entry points still guard against incomplete discovery.
      -- The CMake consumer queues runs instead (covered by tests/overseer.lua).
      local source = require('neotest-cmake.source')
      local definitions, notify, system = source.definitions, vim.notify, vim.system
      local entered, release, finished = nio.control.event(), nio.control.event(), nio.control.event()
      local messages, launches, paused = {}, 0, false
      source.definitions = function(file)
        if not paused then
          paused = true
          entered.set()
          release.wait()
        end
        return definitions(file)
      end
      nio.run(function()
        neotest.cmake.refresh(root)
      end)
      entered.wait()
      local before = runs
      vim.notify = function(message, level)
        messages[#messages + 1] = { message, level }
      end
      vim.system = function(...)
        launches = launches + 1
        return system(...)
      end
      neotest.run.run(path)
      neotest.run.run_last()
      nio.sleep(100)
      source.definitions, vim.notify, vim.system = definitions, notify, system
      vim.api.nvim_create_autocmd('User', {
        pattern = 'NeotestCmakeDiscoveryFinished',
        once = true,
        callback = function(event)
          assert(event.data.root == root)
          finished.set()
        end,
      })
      release.set()
      assert(launches == 0 and runs == before, 'discovery guard started a build or test')
      assert(#messages == 2, 'expected one informative notification per blocked action: ' .. vim.inspect(messages))
      for _, message in ipairs(messages) do
        assert(
          message[1]:find('discovery is still in progress', 1, true) and message[2] == vim.log.levels.INFO,
          vim.inspect(message)
        )
      end
      -- Wait for the entire refresh, including all sibling files, to complete.
      local activity = require('neotest-cmake.activity')
      finished.wait()
      activity.with(root, function()
        assert(not activity.blocked({ '/tmp/unrelated-project/tests.cpp' }), 'blocked unrelated project')
        assert(not activity.blocked({ path, adapter = 'other-adapter:' .. root }), 'blocked another adapter')
      end)
      local ok = pcall(function()
        activity.with(root, function()
          error('parse failure')
        end)
      end)
      assert(not ok and not activity.blocked({ root }), 'failed discovery left run guard active')
    end
    invoke('file run', function()
      neotest.cmake.run(path)
    end)
    local id = 'neotest-cmake:' .. root
    local tree = assert(client:get_position(path, { adapter = id }))
    local count = 0
    for _, node in tree:iter_nodes() do
      if node:data().type == 'test' then
        count = count + 1
      end
    end
    assert(count == #expected, 'wrong number of parameter rows: ' .. count)
    for _, name in ipairs(expected) do
      local pos = assert(tree:get_key(path .. '::' .. name), 'missing ' .. name):data()
      assert(pos.name == name, 'display name differs from GoogleTest')
      assert(concrete[pos.id], 'missing result for ' .. name)
    end
    local function source_mark(name, status)
      local node = assert(tree:get_key(path .. '::' .. name))
      local line = node:data().range[1] + 1
      local buf = vim.fn.bufnr(path)
      local signs
      for _ = 1, 100 do
        nio.sleep(20)
        signs = {}
        for _, sign in ipairs(vim.fn.sign_getplaced(buf, { group = 'neotest-status' })[1].signs) do
          if sign.lnum == line then
            signs[#signs + 1] = sign
          end
        end
        if #signs == 1 and signs[1].name == 'neotest_' .. status then
          break
        end
      end
      assert(
        #signs == 1 and signs[1].name == 'neotest_' .. status,
        name .. ': expected one ' .. status .. ' source mark, got ' .. vim.inspect(signs)
      )
      local marks = {}
      local ns = vim.api.nvim_get_namespaces()['neotest-status']
      for _, mark in
        ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { line - 1, 0 }, { line - 1, -1 }, { details = true }))
      do
        if mark[4].virt_text then
          marks[#marks + 1] = mark
        end
      end
      assert(#marks == 1, name .. ': multiple source status labels')
      assert(
        marks[1][4].virt_text[1][2] == require('neotest.config').highlights[status],
        name .. ': wrong virtual-text status'
      )
    end
    do
      local prepare = adapter.prepare
      local checked = false
      adapter.prepare = function(...)
        checked = true
        for _, pos in tree:iter() do
          assert(client:is_running(pos.id, { adapter = id }), 'not running before build: ' .. pos.id)
          assert(not client:get_results(id)[pos.id], 'old result visible during build: ' .. pos.id)
        end
        source_mark('Basic.Pass', 'running')
        source_mark('Values.Positive', 'running')
        source_mark('Values.Mixed', 'running')
        source_mark('Typed.Size', 'running')
        return prepare(...)
      end
      local ok, reason = pcall(function()
        invoke('loading during preparation', function()
          neotest.cmake.run(path)
        end)
      end)
      adapter.prepare = prepare
      assert(ok, reason)
      assert(checked, 'preparation was not checked')
    end
    do
      source_mark('Values.Mixed', 'failed')
      source_mark('Values.Positive', 'passed')
      source_mark('Typed.Size', 'passed')
      source_mark('TypeParameters.Size', 'passed')
      for name, status in pairs({
        ['Numbers/Values.Mixed/0'] = 'passed',
        ['Numbers/Values.Mixed/1'] = 'skipped',
        ['Named/Values.Mixed/Three'] = 'failed',
      }) do
        assert(concrete[path .. '::' .. name].status == status, 'lost individual parameter status')
        local child = assert(tree:get_key(path .. '::' .. name))
        assert(
          child:closest_value_for('range')[1] == tree:get_key(path .. '::Values.Mixed'):data().range[1],
          'parameter navigation lost its source location'
        )
      end
    end
    do
      local original = require('neotest-cmake.discovery').read(path)
      local function write(text)
        write_fixture(path, text)
      end
      local checked, reason = xpcall(function()
        local failing = original:gsub('EXPECT_GT%(GetParam%(%), 0%);', 'EXPECT_NE(GetParam(), 2);', 1)
        assert(failing ~= original, 'fixture expectation not found')
        write(failing)
        invoke('new failing instance', function()
          neotest.cmake.run({ path .. '::Numbers/Values.Positive/1', adapter = id })
        end)
        assert(
          concrete[path .. '::Numbers/Values.Positive/1'].status == 'failed',
          vim.inspect(concrete[path .. '::Numbers/Values.Positive/1'])
        )
        source_mark('Values.Positive', 'failed')
        write(original)
        invoke('fixed failing instance', function()
          neotest.cmake.run({ path .. '::Numbers/Values.Positive/1', adapter = id })
        end)
        source_mark('Values.Positive', 'passed')
      end, debug.traceback)
      write(original)
      adapter.prepare(tree)
      assert(checked, reason)
    end
    local single_name = 'Numbers/Values.Positive/1'
    invoke('exact instance', function()
      neotest.cmake.run({ path .. '::' .. single_name, adapter = id })
    end)
    local test_count = 0
    for position, result in pairs(concrete) do
      if tree:get_key(position) and tree:get_key(position):data().type == 'test' then
        assert(position == path .. '::' .. single_name and result.status == 'passed', 'ran a sibling instance')
        test_count = test_count + 1
      end
    end
    assert(test_count == 1)
    invoke('rerun last', function()
      neotest.run.run_last()
    end)
    do
      -- A passing parameter rerun must not hide a failed sibling on this line.
      invoke('passing mixed instance', function()
        neotest.cmake.run({ path .. '::Numbers/Values.Mixed/0', adapter = id })
      end)
      source_mark('Values.Mixed', 'failed')
    end
    for _, boundary in ipairs({ adapter, require('neotest-cmake.project') }) do
      local original = require('neotest-cmake.discovery').read(path)
      local prepare, system, edited, launches = boundary.prepare, vim.system, false, 0
      boundary.prepare = function(selected)
        local returned = { prepare(selected) }
        if returned[1] and not edited then
          edited = true
          write_fixture(path, original .. '\n#error changed_after_preparation\n')
        end
        return unpack(returned, 1, boundary == adapter and 5 or 2)
      end
      vim.system = function(command, ...)
        if
          vim.tbl_contains(command, '--gtest_list_tests')
          or (vim.fs.basename(command[1]) == 'ctest' and not vim.tbl_contains(command, '--show-only=json-v1'))
        then
          launches = launches + 1
        end
        return system(command, ...)
      end
      local ok, reason = xpcall(function()
        invoke('edit after preparation', function()
          neotest.cmake.run(path)
        end, 2)
        assert(launches == 0, 'source changed after preparation but the stale binary ran')
        nio.sleep(50)
        assert(not client:get_results(id)[path .. '::Basic.Pass'], 'failed handoff retained stale results')
      end, debug.traceback)
      boundary.prepare, vim.system = prepare, system
      write_fixture(path, original)
      invoke('recover changed preparation', function()
        neotest.cmake.run(path)
      end)
      assert(ok, reason)
    end
    local group_name = 'Values.Positive'
    local group = tree:get_key(path .. '::' .. group_name)
    vim.api.nvim_win_set_cursor(0, { group:data().range[1] + 1, 0 })
    invoke('nearest definition', function()
      neotest.cmake.run()
    end)
    local passed = 0
    for position, result in pairs(concrete) do
      if tree:get_key(position) and tree:get_key(position):data().type == 'test' and result.status == 'passed' then
        passed = passed + 1
      end
    end
    assert(passed == 4, 'nearest run lost parameter instances')
    do
      local original = require('neotest-cmake.discovery').read(path)
      local function write(text)
        write_fixture(path, text)
      end
      local changed, reason = xpcall(function()
        write(original .. '\nINSTANTIATE_TEST_SUITE_P(AddedAtRun, Values, testing::Values(4));\n')
        invoke('file run', function()
          neotest.cmake.run(path)
        end)
        for _, case in ipairs({ 'Positive', 'Mixed' }) do
          local key = path .. '::AddedAtRun/Values.' .. case .. '/0'
          assert(client:get_position(key, { adapter = id }), 'build did not refresh parameter positions')
          assert(concrete[key] and concrete[key].status == 'passed', 'new parameter was not executed')
        end
      end, debug.traceback)
      write(original)
      adapter.prepare(tree)
      neotest.cmake.refresh(path)
      assert(changed, reason)
    end
    do
      local original = require('neotest-cmake.discovery').read(path)
      local notify, system, messages, launches = vim.notify, vim.system, {}, {}
      local sibling = root .. '/cases_extra.cpp'
      local other = root .. '/second.cpp'
      for _, file in ipairs({ sibling, other }) do
        client:_update_positions(file, { adapter = id })
        invoke('seed sibling result', function()
          neotest.cmake.run(file)
        end)
      end
      local other_key, sibling_key = other .. '::SecondBinary.Pass', sibling .. '::SharedBinary.Pass'
      assert(client:get_results(id)[other_key].status == 'passed')
      assert(client:get_results(id)[sibling_key].status == 'passed')
      local executables = {}
      for _, exe in ipairs(require('neotest-cmake.discovery').artifacts(vim.fs.normalize(root .. '/' .. build), '')) do
        executables[vim.uv.fs_realpath(exe) or exe] = true
      end
      local function write(text)
        write_fixture(path, text)
      end
      local function neutral()
        nio.sleep(50)
        local known = client:get_results(id)
        for _, name in ipairs(expected) do
          local key = path .. '::' .. name
          assert(not known[key], 'stale test result survived a failed build: ' .. name)
          assert(not client:is_running(key, { adapter = id }), 'blocked test is still running')
        end
        assert(not known[sibling_key], 'another file in the failed binary retained a passing result')
        assert(known[other_key] and known[other_key].status == 'passed', 'unrelated binary lost its result')
        source_mark('Basic.Pass', 'test')
        source_mark('Values.Positive', 'namespace')
        source_mark('Values.Mixed', 'namespace')
        source_mark('Typed.Size', 'namespace')
        source_mark('TypeParameters.Size', 'namespace')
        assert(#launches == 0, 'stale executable or CTest run launched: ' .. vim.inspect(launches))
      end
      local checked, reason = xpcall(function()
        write(original .. '\n#error intentional_quickfix_failure\n')
        vim.notify = function(message)
          messages[#messages + 1] = message
        end
        vim.system = function(command, ...)
          local exe = vim.uv.fs_realpath(command[1]) or command[1]
          if
            executables[exe]
            or (vim.fs.basename(exe) == 'ctest' and not vim.tbl_contains(command, '--show-only=json-v1'))
          then
            launches[#launches + 1] = vim.deepcopy(command)
          end
          return system(command, ...)
        end
        -- Simulate save-triggered discovery before invoking the run keymap.
        client:_update_positions(path, { adapter = id })
        assert(#launches == 0, 'saving a changed source enumerated its old binary')
        local previous, previous_runs = run_count, runs
        neotest.cmake.run(path)
        neutral()
        assert(
          run_count == previous and runs == previous_runs + 1,
          'failed build did not emit only the preparation event'
        )
        assert(vim.fn.getqflist({ winid = 0 }).winid > 0, 'consumer did not open quickfix')
        assert(vim.api.nvim_buf_get_name(0) == path, 'quickfix stole focus from the source buffer')
        -- Discovery and retries after failure preserve parameter rows without
        -- launching the binary. Selecting the unchanged sibling must also fail.
        client:_update_positions(path, { adapter = id })
        for _, name in ipairs(expected) do
          assert(client:get_position(path .. '::' .. name, { adapter = id }))
        end
        neotest.cmake.run(sibling)
        neutral()
        invoke('plain Neotest failed build', function()
          neotest.run.run(path)
        end)
        neutral()
        assert(#messages == 0, 'build failure emitted an error notification: ' .. vim.inspect(messages))
      end, debug.traceback)
      vim.notify, vim.system = notify, system
      write(original)
      invoke('rebuild after compiler error', function()
        neotest.cmake.run(path)
      end)
      source_mark('Values.Positive', 'passed')
      source_mark('Values.Mixed', 'failed')
      assert(client:get_results(id)[other_key].status == 'passed')
      invoke('recover sibling result', function()
        neotest.cmake.run(sibling)
      end)
      assert(client:get_results(id)[sibling_key].status == 'passed')
      assert(#vim.fn.getqflist() == 0, 'successful build left stale quickfix diagnostics')
      assert(checked, reason)
    end
    neotest.summary.open()
    neotest.summary:expand(path, true)
    local summary
    for _ = 1, 100 do
      nio.sleep(20)
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].filetype == 'neotest-summary' then
          summary = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
        end
      end
      if summary and summary:find(expected[#expected], 1, true) then
        break
      end
    end
    for _, name in ipairs(expected) do
      local row_count = 0
      for _, line in ipairs(vim.split(summary or '', '\n', { plain = true })) do
        if line:sub(-#name - 1) == ' ' .. name then
          row_count = row_count + 1
        end
      end
      assert(row_count == 1, 'expected exactly one summary row for ' .. name .. ', got ' .. row_count)
    end
    io.stdout:write(summary .. '\n')
    io.stdout:write('Neotest UI checks passed: concrete parameter rows, file, nearest and exact-instance runs\n')
  end, debug.traceback)
  nio.scheduler()
  if not ok then
    io.stderr:write(err .. '\n')
    vim.cmd('cquit 1')
  else
    vim.cmd('qa!')
  end
end)
