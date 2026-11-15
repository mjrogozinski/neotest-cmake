-- Real Neotest client, runner and summary; no mocked execution or UI rendering.
require('nio').run(function()
  local nio = require('nio')
  nio.scheduler()
  local ok, err = xpcall(function()
    local warmup = vim.env.WARMUP_ROOT
    local root = warmup or vim.fn.getcwd() .. '/tests/fixture'
    root = assert(vim.uv.fs_realpath(root))
    local path = root .. (warmup and '/tests/different_test.cpp' or '/cases.cpp')
    local build = warmup and (vim.env.NEOTEST_BUILD_DIR or 'build/clang') or '../../build/fixture'
    local adapter = require('neotest-cmake')({ root = root, build_dir = build })
    local neotest, client = require('neotest'), nil
    local concrete, run_count = {}, 0
    -- The test uses the main process parser, including CPP_PARSER_DIR.
    require('neotest.lib').subprocess.init = function() end
    neotest.setup({
      adapters = { adapter }, discovery = { enabled = false },
      status = { signs = true, virtual_text = true },
      consumers = {
        cmake = require('neotest-cmake.consumer'),
        check = function(c)
          client = c
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
    local expected = warmup and {
      'Different.Test_1',
      'Numeric/DifferentTest.IsPositive/0', 'Numeric/DifferentTest.IsPositive/1', 'Numeric/DifferentTest.IsPositive/2',
      'Named/DifferentTest.IsPositive/Value4', 'Named/DifferentTest.IsPositive/Value5',
      'Numeric/DifferentTest.DoublesExactly/0', 'Numeric/DifferentTest.DoublesExactly/1', 'Numeric/DifferentTest.DoublesExactly/2',
      'Named/DifferentTest.DoublesExactly/Value4', 'Named/DifferentTest.DoublesExactly/Value5',
      'DifferentTypedTest/0.HasSize', 'DifferentTypedTest/1.HasSize',
      'Types/DifferentTypeParameterizedTest/0.HasSize', 'Types/DifferentTypeParameterizedTest/1.HasSize',
    } or {
      'Basic.Pass', 'Basic.Fail', 'Basic.Skip', 'Basic.DISABLED_Off',
      'Numbers/Values.Positive/0', 'Numbers/Values.Positive/1', 'Named/Values.Positive/Three',
      'Numbers/Values.Mixed/0', 'Numbers/Values.Mixed/1', 'Named/Values.Mixed/Three',
      'Values.Positive/0', 'Values.Mixed/0',
      'Typed/0.Size', 'Typed/1.Size', 'Instances/TypeParameters/0.Size', 'Instances/TypeParameters/1.Size',
    }
    -- Optionally exercise the user's actual keymap callbacks, with this isolated
    -- Neotest setup instead of loading all unrelated editor plugins.
    local mappings = {}
    if vim.env.NEOTEST_KEYMAP_SPEC then
      vim.opt.rtp:append(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.env.NEOTEST_KEYMAP_SPEC))))
      for _, map in ipairs(dofile(vim.env.NEOTEST_KEYMAP_SPEC).keys) do mappings[map[1]] = map[2] end
    end
    local function invoke(lhs, fallback)
      local previous = run_count
      if mappings[lhs] then mappings[lhs]() else fallback() end
      for _ = 1, 3000 do
        if run_count > previous then break end
        nio.sleep(20)
      end
      assert(run_count > previous, lhs .. ' did not finish')
    end
    invoke('<leader>if', function() neotest.cmake.run(path) end)
    local id = 'neotest-cmake:' .. root
    local tree = assert(client:get_position(path, { adapter = id }))
    local count = 0
    for _, node in tree:iter_nodes() do if node:data().type == 'test' then count = count + 1 end end
    assert(count == #expected, 'wrong number of parameter rows: ' .. count)
    for _, name in ipairs(expected) do
      local pos = assert(tree:get_key(path .. '::' .. name), 'missing ' .. name):data()
      assert(pos.name == name, 'display name differs from GoogleTest')
      local result = assert(concrete[pos.id], 'missing result for ' .. name)
      if warmup then assert(result.status == 'passed', name .. ': ' .. vim.inspect(result)) end
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
          if sign.lnum == line then signs[#signs + 1] = sign end
        end
        if #signs == 1 and signs[1].name == 'neotest_' .. status then break end
      end
      assert(#signs == 1 and signs[1].name == 'neotest_' .. status,
        name .. ': expected one ' .. status .. ' source mark, got ' .. vim.inspect(signs))
      local marks = {}
      local ns = vim.api.nvim_get_namespaces()['neotest-status']
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { line - 1, 0 }, { line - 1, -1 }, { details = true })) do
        if mark[4].virt_text then marks[#marks + 1] = mark end
      end
      assert(#marks == 1, name .. ': multiple source status labels')
      assert(marks[1][4].virt_text[1][2] == require('neotest.config').highlights[status],
        name .. ': wrong virtual-text status')
    end
    if not warmup then
      source_mark('Values.Mixed', 'failed')
      source_mark('Values.Positive', 'passed')
      source_mark('Typed.Size', 'passed')
      source_mark('TypeParameters.Size', 'passed')
      for name, status in pairs({ ['Numbers/Values.Mixed/0'] = 'passed',
        ['Numbers/Values.Mixed/1'] = 'skipped', ['Named/Values.Mixed/Three'] = 'failed' }) do
        assert(concrete[path .. '::' .. name].status == status, 'lost individual parameter status')
        local child = assert(tree:get_key(path .. '::' .. name))
        assert(child:closest_value_for('range')[1] == tree:get_key(path .. '::Values.Mixed'):data().range[1],
          'parameter navigation lost its source location')
      end
    end
    if not warmup then
      local original = require('neotest-cmake.discovery').read(path)
      local function write(text)
        local file = assert(io.open(path, 'w')); file:write(text); file:close()
      end
      local checked, reason = xpcall(function()
        local failing = original:gsub('EXPECT_GT%(GetParam%(%), 0%);', 'EXPECT_NE(GetParam(), 2);', 1)
        assert(failing ~= original, 'fixture expectation not found')
        write(failing)
        invoke('new failing instance', function()
          neotest.cmake.run({ path .. '::Numbers/Values.Positive/1', adapter = id })
        end)
        assert(concrete[path .. '::Numbers/Values.Positive/1'].status == 'failed')
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
    local single_name = warmup and 'Numeric/DifferentTest.IsPositive/1' or 'Numbers/Values.Positive/1'
    invoke('exact instance', function() neotest.cmake.run({ path .. '::' .. single_name, adapter = id }) end)
    local test_count = 0
    for position, result in pairs(concrete) do
      if tree:get_key(position) and tree:get_key(position):data().type == 'test' then
        assert(position == path .. '::' .. single_name and result.status == 'passed', 'ran a sibling instance')
        test_count = test_count + 1
      end
    end
    assert(test_count == 1)
    if not warmup then
      -- A passing parameter rerun must not hide a failed sibling on this line.
      invoke('passing mixed instance', function()
        neotest.cmake.run({ path .. '::Numbers/Values.Mixed/0', adapter = id })
      end)
      source_mark('Values.Mixed', 'failed')
    end
    local group_name = warmup and 'DifferentTest.IsPositive' or 'Values.Positive'
    local group = tree:get_key(path .. '::' .. group_name)
    vim.api.nvim_win_set_cursor(0, { group:data().range[1] + 1, 0 })
    invoke('<leader>ir', function() neotest.cmake.run() end)
    local passed = 0
    for position, result in pairs(concrete) do
      if tree:get_key(position) and tree:get_key(position):data().type == 'test' and result.status == 'passed' then passed = passed + 1 end
    end
    assert(passed == (warmup and 5 or 4), 'nearest run lost parameter instances')
    if not warmup then
      local original = require('neotest-cmake.discovery').read(path)
      local function write(text)
        local file = assert(io.open(path, 'w')); file:write(text); file:close()
      end
      local changed, reason = xpcall(function()
        write(original .. '\nINSTANTIATE_TEST_SUITE_P(AddedAtRun, Values, testing::Values(4));\n')
        invoke('<leader>if', function() neotest.cmake.run(path) end)
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
    if warmup and mappings['<leader>iA'] then
      invoke('<leader>iA', function() end)
      assert(concrete[root .. '/tests/ranges_test.cpp::Ranges.EmptyInput'].status == 'passed')
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
      if summary and summary:find(expected[#expected], 1, true) then break end
    end
    for _, name in ipairs(expected) do assert(summary and summary:find(name, 1, true), 'missing summary row: ' .. name) end
    print(summary)
    print('Neotest UI checks passed: concrete parameter rows, file, nearest and exact-instance runs')
  end, debug.traceback)
  nio.scheduler()
  if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
end)
