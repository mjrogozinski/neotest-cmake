local activity = require('neotest-cmake.activity')
local root = vim.fn.getcwd()
local notify, messages = vim.notify, {}
vim.notify = function(message, level) messages[#messages + 1] = { message, level } end
local events = {}
vim.api.nvim_create_autocmd('User', {
  pattern = 'NeotestCmakeDiscoveryFinished',
  callback = function(event) events[#events + 1] = event.data.root end,
})
local ok, err = xpcall(function()
  activity.with(root, function() end)
  assert(#events == 0, 'uninterrupted discovery should not publish a watched completion')
  assert(#messages == 0, 'uninterrupted discovery should be silent')
  local finish = activity.start(root)
  local child = activity.start(root)
  assert(activity.blocked({ root }))
  assert(activity.blocked({ root }))
  assert(#messages == 2)
  child()
  assert(#events == 0, 'published completion before all workers finished')
  assert(#messages == 2, 'announced completion before all workers finished')
  finish()
  assert(#messages == 3 and messages[3][1]:find('You can run tests now.', 1, true)
    and messages[3][2] == vim.log.levels.INFO, 'expected one completion notification')
  assert(#events == 1 and events[1] == root, 'missing project completion event')
  finish()
  activity.with(root, function() end)
  assert(#messages == 3, 'completion notification repeated without a blocked request')
  assert(not activity.blocked({ root }))
end, debug.traceback)
vim.notify = notify
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Discovery completion notification checks passed')
vim.cmd('qa!')
