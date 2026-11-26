-- Real asynchronous build/test processes and the actual Neotest consumer.
local nio = require('nio')
local deps = vim.env.NEOTEST_DEPS or vim.fn.expand('~/.local/share/nvim/lazy')
vim.opt.rtp:append(deps .. '/overseer.nvim')
local available, overseer = pcall(require, 'overseer')
if not available then
  if vim.env.NEOTEST_REQUIRE_OVERSEER == '1' then
    error('Overseer is required for this test run')
  end
  io.stdout:write('Skipping optional Overseer integration checks\n')
  vim.cmd('qa!')
  return
end
local watchdog = vim.defer_fn(function()
  io.stderr:write('Timed out waiting for the asynchronous Overseer integration test\n')
  vim.cmd('cquit 1')
end, 120000)
overseer.setup({})
require('neotest.lib').subprocess.init = function() end
nio.run(function()
  nio.scheduler()
  local root = vim.fn.tempname()
  local heartbeat = vim.uv.new_timer()
  local ticks = 0
  heartbeat:start(
    0,
    20,
    vim.schedule_wrap(function()
      ticks = ticks + 1
    end)
  )
  local notify, notifications = vim.notify, {}
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { tostring(message), level }
  end
  local ok, err = xpcall(function()
    vim.fn.mkdir(root .. '/build/.cmake/api/v1/query', 'p')
    root = assert(vim.uv.fs_realpath(root))
    vim.fn.writefile({}, root .. '/build/.cmake/api/v1/query/codemodel-v2')
    vim.fn.writefile({
      'cmake_minimum_required(VERSION 3.21)',
      'project(async_tests LANGUAGES CXX)',
      'enable_testing()',
      'find_package(GTest CONFIG REQUIRED)',
      'add_executable(cases cases.cpp)',
      'target_link_libraries(cases PRIVATE GTest::gtest_main)',
      'include(GoogleTest)',
      'gtest_discover_tests(cases)',
    }, root .. '/CMakeLists.txt')
    local path = root .. '/cases.cpp'
    local function source(failing)
      vim.fn.writefile({
        '#include <gtest/gtest.h>',
        '#include <thread>',
        '#include <chrono>',
        'TEST(Async, Case) { std::this_thread::sleep_for(std::chrono::seconds(1)); EXPECT_TRUE('
          .. (failing and 'false' or 'true')
          .. '); }',
        'class ValueChecks : public testing::TestWithParam<int> {};',
        'TEST_P(ValueChecks, Positive) { EXPECT_GT(GetParam(), 0); }',
        'INSTANTIATE_TEST_SUITE_P(Inputs, ValueChecks, testing::Values(1, 2));',
      }, path)
    end
    source(false)
    -- Delay the real build too, so responsiveness is checked in both stages.
    local cmake = root .. '/cmake'
    vim.fn.writefile({ '#!/bin/sh', 'sleep 1', 'exec cmake "$@"' }, cmake)
    vim.fn.setfperm(cmake, 'rwx------')
    local event, configured = nio.control.event(), nil
    vim.system({ 'cmake', '-S', root, '-B', root .. '/build' }, { text = true }, function(result)
      configured = result
      event.set()
    end)
    event.wait()
    nio.scheduler()
    assert(configured.code == 0, configured.stderr)
    local neotest = require('neotest')
    local client, started_runs = nil, 0
    neotest.setup({
      adapters = { require('neotest-cmake')({ root = root, build_dir = 'build', cmake = cmake }) },
      discovery = { enabled = false },
      consumers = {
        cmake = require('neotest-cmake.consumer'),
        overseer = require('neotest.consumers.overseer'),
        check = function(c)
          client = c
          c.listeners.run = function()
            started_runs = started_runs + 1
          end
          return {}
        end,
      },
    })
    vim.cmd.edit(path)
    local function children(parent)
      return vim.tbl_filter(function(t)
        return t.parent_id == parent.id
      end, overseer.list_tasks({ include_ephemeral = true }))
    end
    local function wait_for(check)
      for _ = 1, 3000 do
        if check() then
          return
        end
        nio.sleep(20)
      end
      error('Timed out waiting for task')
    end
    local function invoke()
      local existing = {}
      for _, t in ipairs(overseer.list_tasks({})) do
        existing[t.id] = true
      end
      neotest.cmake.run(path)
      local parent
      wait_for(function()
        for _, t in ipairs(overseer.list_tasks({})) do
          if not existing[t.id] and t.name:find('Build and test', 1, true) then
            parent = t
            return true
          end
        end
      end)
      return parent
    end
    local function complete(parent, status, count)
      local progress, attempts = {}, 0
      while not parent:is_complete() do
        attempts = attempts + 1
        assert(attempts < 3000, 'parent task did not finish')
        for _, child in ipairs(children(parent)) do
          if child:is_running() then
            local stage = child.name
            progress[stage] = progress[stage] or { ticks, ticks }
            progress[stage][2] = ticks
            if stage == 'Build tests' then
              local id = 'neotest-cmake:' .. root
              local selected = assert(client:get_position(path, { adapter = id }))
              for _, pos in selected:iter() do
                assert(client:is_running(pos.id, { adapter = id }), 'build did not mark running: ' .. pos.id)
                assert(not client:get_results(id)[pos.id], 'build retained old result: ' .. pos.id)
              end
            end
            if stage == 'Run tests' then
              local build_finished = false
              for _, sibling in ipairs(children(parent)) do
                if sibling.name == 'Build tests' then
                  build_finished = sibling.status == 'SUCCESS'
                end
              end
              assert(build_finished, 'tests started before a successful build')
            end
          end
        end
        nio.sleep(20)
      end
      assert(parent.status == status, vim.inspect({ parent.status, children(parent) }))
      assert(#children(parent) == count, 'unexpected number of subtasks')
      for stage, span in pairs(progress) do
        assert(span[2] - span[1] >= 10, 'main loop stalled during ' .. stage)
      end
      if count == 2 then
        assert(progress['Build tests'] and progress['Run tests'])
        local adapter_id = 'neotest-cmake:' .. root
        local known = client:get_results(adapter_id)
        assert(
          known[path .. '::Async.Case'].status == (status == 'SUCCESS' and 'passed' or 'failed'),
          'Neotest retained a stale case result'
        )
        for _, name in ipairs({ 'Inputs/ValueChecks.Positive/0', 'Inputs/ValueChecks.Positive/1' }) do
          assert(known[path .. '::' .. name].status == 'passed', 'lost parameter result: ' .. name)
        end
        local seen, tests = {}, 0
        for _, pos in client:get_position(path, { adapter = adapter_id }):iter() do
          assert(not seen[pos.id], 'duplicate position: ' .. pos.id)
          seen[pos.id] = true
          if pos.type == 'test' then
            tests = tests + 1
          end
        end
        assert(tests == 3, 'unexpected test count after refresh: ' .. tests)
        neotest.summary.open()
        neotest.summary:expand(path, true)
        local expected =
          { 'Async.Case', 'ValueChecks.Positive', 'Inputs/ValueChecks.Positive/0', 'Inputs/ValueChecks.Positive/1' }
        wait_for(function()
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[buf].filetype == 'neotest-summary' then
              local counts = {}
              for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
                for _, name in ipairs(expected) do
                  if line:sub(-#name - 1) == ' ' .. name then
                    counts[name] = (counts[name] or 0) + 1
                  end
                end
              end
              for _, name in ipairs(expected) do
                assert((counts[name] or 0) <= 1, 'duplicate summary row: ' .. name)
                if not counts[name] then
                  return false
                end
              end
              return true
            end
          end
        end)
      end
      assert(#notifications == 0, 'build/test completion emitted a notification: ' .. vim.inspect(notifications))
    end
    local parent = invoke()
    complete(parent, 'SUCCESS', 2)
    -- Mimic save-triggered discovery, held across a single run request.
    -- Both result transitions must build and run without a second invocation.
    local definitions = require('neotest-cmake.source').definitions
    local activity = require('neotest-cmake.activity')
    for _, failing in ipairs({ true, false, true }) do
      source(failing)
      local before_runs = started_runs
      local entered, release, finished = nio.control.event(), nio.control.event(), nio.control.event()
      local held = false
      require('neotest-cmake.source').definitions = function(file)
        if file == path and not held then
          held = true
          entered.set()
          release.wait()
        end
        return definitions(file)
      end
      nio.run(function()
        neotest.cmake.refresh(root)
        finished.set()
      end)
      entered.wait()
      local before = ticks
      local requested, queued = nio.control.event(), nil
      nio.run(function()
        queued = invoke()
        requested.set()
      end)
      nio.sleep(200)
      assert(not queued, 'run started before discovery completed')
      assert(ticks - before >= 5, 'waiting for discovery blocked the editor')
      release.set()
      finished.wait()
      requested.wait()
      require('neotest-cmake.source').definitions = definitions
      parent = queued
      complete(parent, failing and 'FAILURE' or 'SUCCESS', 2)
      assert(
        started_runs == before_runs + 2,
        'expected preparation and execution events: ' .. (started_runs - before_runs)
      )
      assert(not activity.blocked({ path }), 'discovery left the run guard active')
    end
    source(false)
    parent:reset()
    parent:start()
    complete(parent, 'SUCCESS', 2)
    local before_failure = started_runs
    vim.fn.writefile({ 'invalid C++' }, path, 'a')
    parent = invoke()
    complete(parent, 'FAILURE', 1)
    assert(started_runs == before_failure + 1, 'failed build emitted an execution event')
    source(false)
    parent = invoke()
    wait_for(function()
      return #children(parent) > 0
    end)
    parent:stop()
    nio.sleep(100)
    assert(parent.status == 'CANCELED')
    for _, child in ipairs(children(parent)) do
      assert(not child:is_running())
    end
    io.stdout:write('Overseer async build/test, failure, restart and cancellation checks passed\n')
  end, debug.traceback)
  watchdog:stop()
  watchdog:close()
  vim.notify = notify
  for _, task in ipairs(overseer.list_tasks({ include_ephemeral = true })) do
    if task.cwd == root and task:is_running() then
      task:stop()
    end
  end
  heartbeat:stop()
  heartbeat:close()
  nio.scheduler()
  vim.fn.delete(root, 'rf')
  if not ok then
    io.stderr:write(err .. '\n')
    vim.cmd('cquit 1')
  else
    vim.cmd('qa!')
  end
end)
