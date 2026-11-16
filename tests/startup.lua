-- Reproduce `cd /tmp/project; nvim relative/test.cc; <leader>if` while
-- initial project discovery is still finding files, before source parsing.
local nio = require('nio')
nio.run(function()
  nio.scheduler()
  local ok, err = xpcall(function()
    local root = assert(vim.uv.fs_realpath(vim.fn.getcwd() .. '/tests/fixture'))
    local alias = vim.fn.tempname()
    assert(vim.uv.fs_symlink(root, alias, { dir = true }))
    vim.cmd.cd(alias)
    vim.cmd.edit('cases.cpp')
    local activity = require('neotest-cmake.activity')
    local adapter = require('neotest-cmake') { root = root, build_dir = '../../build/fixture' }
    local neotest, client = require('neotest'), nil
    require('neotest.lib').subprocess.init = function() end
    neotest.setup {
      adapters = { adapter }, discovery = { enabled = true },
      consumers = {
        cmake = require('neotest-cmake.consumer'),
        check = function(c) client = c; return {} end,
      },
    }
    local files = require('neotest.lib').files
    local find, notify, system = files.find, vim.notify, vim.system
    local entered, release, done = nio.control.event(), nio.control.event(), nio.control.event()
    local first, startup_error = true, nil
    files.find = function(path, ...)
      if first then
        first = false
        entered.set()
        release.wait()
      end
      return find(path, ...)
    end
    nio.run(function()
      local success, reason = pcall(function() client:get_adapters() end)
      if not success then startup_error = reason end
      done.set()
    end)
    entered.wait()
    local messages, launches = {}, 0
    vim.notify = function(message, level) messages[#messages + 1] = { message, level } end
    vim.system = function(...) launches = launches + 1; return system(...) end
    local qf = vim.fn.getqflist({ changedtick = 0, title = 0 })
    for _ = 1, 3 do neotest.cmake.run(vim.fn.expand('%')) end
    neotest.cmake.run { 'cases.cpp', strategy = 'dap' }
    neotest.run.run('cases.cpp')
    neotest.run.run { alias .. '/cases.cpp::Basic.Pass', adapter = 'neotest-cmake:' .. alias }
    neotest.cmake.run { root, adapter = 'neotest-cmake:' .. root }
    nio.sleep(100)
    vim.notify, vim.system, files.find = notify, system, find
    release.set()
    done.wait()
    assert(not startup_error, startup_error)
    assert(launches == 0, 'startup requests launched a build or test')
    assert(vim.deep_equal(qf, vim.fn.getqflist({ changedtick = 0, title = 0 })), 'startup requests changed quickfix')
    assert(#messages == 7, 'wrong notification count: ' .. vim.inspect(messages))
    for _, message in ipairs(messages) do
      assert(message[1]:find('discovery is still in progress', 1, true)
        and message[2] == vim.log.levels.INFO, vim.inspect(message))
    end
    assert(not activity.blocked('cases.cpp'), 'startup scope was not released')
    -- The same relative-path action must work normally once startup finishes.
    local completed = nio.control.event()
    client.listeners.results = function(_, _, partial) if not partial then completed.set() end end
    neotest.cmake.run('cases.cpp')
    completed.wait()
    assert(client:get_results('neotest-cmake:' .. root)[root .. '/cases.cpp::Basic.Pass'].status == 'passed')
    vim.uv.fs_unlink(alias)
  end, debug.traceback)
  if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
  print('Startup discovery checks passed: relative paths, symlinks, repeated runs and untouched quickfix')
  vim.cmd('qa!')
end)
