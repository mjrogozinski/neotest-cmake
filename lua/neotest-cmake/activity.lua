local M = {}
local active, waiting, completions = {}, {}, {}

vim.api.nvim_create_autocmd('User', {
  group = vim.api.nvim_create_augroup('neotest-cmake-discovery', { clear = true }),
  pattern = 'NeotestCmakeDiscoveryFinished',
  callback = function(event)
    vim.notify('CMake test discovery finished for ' .. event.data.root .. '. You can run tests now.', vim.log.levels.INFO)
  end,
})

local function canonical(path)
  path = vim.fn.fnamemodify(path, ':p')
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

-- Keep startup/refresh scopes active between individual source workers.
function M.start(root)
  if not root then return function() end end
  root = canonical(root)
  if not active[root] then completions[root] = require('nio').control.event() end
  active[root] = (active[root] or 0) + 1
  local finished = false
  return function()
    if finished then return end
    finished = true
    active[root] = active[root] - 1
    if active[root] == 0 then
      active[root] = nil
      local done = completions[root]
      completions[root] = nil
      done.set()
      if waiting[root] then
        waiting[root] = nil
        vim.api.nvim_exec_autocmds('User', {
          pattern = 'NeotestCmakeDiscoveryFinished', modeline = false, data = { root = root },
        })
      end
    end
  end
end

function M.with(root, callback)
  local finish = M.start(root)
  local result = { pcall(callback) }
  finish()
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2)
end

local function active_project(args)
  args = type(args) == 'string' and { args } or args or {}
  if args.adapter and not vim.startswith(args.adapter, 'neotest-cmake:') then return false end
  local path = args[1] or vim.api.nvim_buf_get_name(0)
  -- Position IDs append ::suite.case; resolve only the filesystem portion.
  path = path ~= '' and path or vim.uv.cwd()
  path = canonical(path:match('^(.-)::') or path)
  local root = args.adapter and args.adapter:sub(#'neotest-cmake:' + 1)
  root = root and canonical(root)
  for project in pairs(active) do
    if root == project or (not root and (path == project or vim.startswith(path, project .. '/')
      or vim.startswith(path, project .. '::'))) then
      return project
    end
  end
end

-- Saving can start a scan immediately before the run keymap calls us. Keep
-- that request alive while discovery yields, then resolve the updated tree.
function M.wait(args)
  local nio = require('nio')
  nio.scheduler()
  local project = active_project(args)
  while project do
    completions[project].wait()
    nio.scheduler()
    project = active_project(args)
  end
end

function M.blocked(args)
  local project = active_project(args)
  if not project then return false end
  waiting[project] = true
  vim.notify('CMake test discovery is still in progress. Please wait, then run tests again.', vim.log.levels.INFO)
  return true
end
return M
