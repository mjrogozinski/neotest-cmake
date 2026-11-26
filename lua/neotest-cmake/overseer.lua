-- Optional Overseer integration. All waits yield through nio.
local M = {}
-- Keep status and output, without command-line completion notifications.
M.components = { 'on_exit_set_status', { 'on_complete_dispose', require_view = { 'SUCCESS', 'FAILURE' } } }
function M.parent(root, name, run)
  local ok, overseer = pcall(require, 'overseer')
  if not ok then
    return
  end
  local parent = overseer.new_task({
    name = 'Build and test ' .. name,
    cwd = root,
    strategy = { 'neotest_cmake', run = run },
    components = M.components,
  })
  parent:subscribe('on_dispose', function()
    for _, child in ipairs(overseer.list_tasks({ include_ephemeral = true })) do
      if child.parent_id == parent.id then
        child:dispose(true)
      end
    end
  end)
  parent:subscribe('on_status', function(_, status)
    if status == 'CANCELED' then
      for _, child in ipairs(overseer.list_tasks({ include_ephemeral = true })) do
        if child.parent_id == parent.id and child:is_running() then
          child:stop()
        end
      end
    end
  end)
  vim.api.nvim_buf_set_lines(parent:get_bufnr(), 0, -1, false, { 'Build tests -> Run tests' })
  parent:start()
  return parent
end
function M.finish(parent, success)
  if not parent or not parent:is_running() then
    return
  end
  local lines, ran_tests = {}, false
  for _, child in ipairs(require('overseer').list_tasks({ include_ephemeral = true })) do
    if child.parent_id == parent.id then
      ran_tests = ran_tests or child.name == 'Run tests'
      lines[#lines + 1] = child.status .. ' ' .. child.name
      success = success and child.status == 'SUCCESS'
    end
  end
  vim.api.nvim_buf_set_lines(parent:get_bufnr(), 0, -1, false, lines)
  parent:on_exit(success and ran_tests and 0 or 1)
end
function M.process(parent, command, cwd, timeout)
  if not parent:is_running() then
    return { code = 1, stderr = 'Build cancelled' }
  end
  local nio = require('nio')
  local done = nio.control.event()
  local task = require('overseer').new_task({
    name = vim.tbl_contains(command, '--build') and 'Build tests' or 'Configure tests',
    cmd = command,
    cwd = cwd,
    parent_id = parent.id,
    ephemeral = true,
    strategy = 'system',
    components = M.components,
  })
  task:subscribe('on_complete', function()
    done.set()
    return false
  end)
  local timer = vim.defer_fn(function()
    if task:is_running() then
      task:stop()
    end
  end, timeout)
  task:start()
  done.wait()
  nio.scheduler()
  if not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  local buf = task:get_bufnr()
  local output = buf
      and vim.api.nvim_buf_is_valid(buf)
      and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    or ''
  return { code = task.exit_code or 1, stdout = output, stderr = '' }
end
return M
