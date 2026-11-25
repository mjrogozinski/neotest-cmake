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
    local discovery_finished = nio.control.event()
    vim.api.nvim_create_autocmd('User', {
      pattern = 'NeotestCmakeDiscoveryFinished', once = true,
      callback = function(event)
        assert(event.data.root == root)
        discovery_finished.set()
      end,
    })
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
    local completed, requested = nio.control.event(), nio.control.event()
    client.listeners.results = function(_, _, partial) if not partial then completed.set() end end
    nio.run(function() neotest.cmake.run(vim.fn.expand('%')); requested.set() end)
    neotest.run.run('cases.cpp')
    neotest.run.run { alias .. '/cases.cpp::Basic.Pass', adapter = 'neotest-cmake:' .. alias }
    nio.sleep(100)
    vim.system, files.find = system, find
    release.set()
    done.wait()
    discovery_finished.wait()
    vim.notify = notify
    assert(not startup_error, startup_error)
    assert(launches == 0, 'startup requests launched a build or test')
    assert(vim.deep_equal(qf, vim.fn.getqflist({ changedtick = 0, title = 0 })), 'startup requests changed quickfix')
    assert(#messages == 3, 'wrong notification count: ' .. vim.inspect(messages))
    for i = 1, 2 do
      local message = messages[i]
      assert(message[1]:find('discovery is still in progress', 1, true)
        and message[2] == vim.log.levels.INFO, vim.inspect(message))
    end
    assert(messages[3][1]:find('You can run tests now.', 1, true)
      and messages[3][2] == vim.log.levels.INFO, 'missing completion notification')
    assert(not activity.blocked('cases.cpp'), 'startup scope was not released')
    -- The original relative-path action resumes without another invocation.
    requested.wait()
    completed.wait()
    assert(client:get_results('neotest-cmake:' .. root)[root .. '/cases.cpp::Basic.Pass'].status == 'passed')
    vim.uv.fs_unlink(alias)
  end, debug.traceback)
  if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
  print('Startup discovery checks passed: relative paths, symlinks, queued first run and untouched quickfix')
  vim.cmd('qa!')
end)
