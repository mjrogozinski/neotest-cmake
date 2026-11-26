local M = {}

function M.report(root, build, stage, result)
  require('nio').scheduler()
  local summary = 'CMake ' .. stage .. ' failed; tests not run'
  local text = ((result.stdout or '') .. '\n' .. (result.stderr or '')):gsub('\27%[[%d;]*m', '')
  local lines = vim.split(text, '\n', { plain = true })
  local output = vim.fn.tempname() .. '.log'
  vim.fn.writefile(lines, output)
  -- CMake runs the build tool in the binary directory, even when the calling
  -- editor has another cwd. Directory records resolve relative compiler paths.
  local cwd = stage == 'build' and build or root
  local parse = { 'Entering directory ' .. cwd }
  vim.list_extend(parse, lines)
  parse[#parse + 1] = 'Leaving directory ' .. cwd
  local efm = table.concat({
    '%DEntering directory %f',
    '%XLeaving directory %f',
    '%f:%l:%c: fatal error: %m',
    '%f:%l: fatal error: %m',
    '%f:%l:%c: %trror: %m',
    '%f:%l:%c: %tarning: %m',
    '%f:%l:%c: %tote: %m',
    '%f:%l: %trror: %m',
    '%f:%l: %tarning: %m',
    '%f:%l: %tote: %m',
    '%ECMake Error at %f:%l (%*[^)]):',
    '%ECMake Error at %f:%l:',
    '%ECMake Error in %f:',
    '%C  %m',
    '%Z%\\s%#',
    vim.o.errorformat,
  }, ',')
  local items = {}
  for _, item in ipairs(vim.fn.getqflist({ lines = parse, efm = efm }).items) do
    if item.valid == 1 then
      item.type = item.type == '' and 'E' or item.type:upper()
      items[#items + 1] = item
    end
  end
  -- Linker, timeout and configuration errors may have no source location.
  -- Keep them inspectable in the list, with navigation into the full build log.
  if #items == 0 then
    for line, value in ipairs(lines) do
      if value ~= '' then
        items[#items + 1] = { filename = output, lnum = line, text = value, type = 'E' }
      end
    end
  end
  if #items == 0 then
    items[1] = { text = summary .. ' (exit ' .. tostring(result.code) .. ')', type = 'E' }
  end
  vim.fn.setqflist(
    {},
    ' ',
    { title = summary, items = items, context = { neotest_cmake = true, root = root, build = build, output = output } }
  )
  local win = vim.api.nvim_get_current_win()
  vim.cmd('botright copen')
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  return { summary = summary, output = output }
end

function M.clear(root, build)
  local context = vim.fn.getqflist({ context = 0 }).context
  if type(context) == 'table' and context.neotest_cmake and context.root == root and context.build == build then
    vim.fn.setqflist({}, 'r', { title = 'CMake build succeeded', items = {}, context = context })
    vim.cmd('cclose')
  end
end

-- Normal Neotest/summary runs bypass the build consumer. Return an already
-- completed strategy on failure so Neotest clears running state without
-- launching a stale test executable or raising an exception.
function M.blocked(tree, failure)
  local tests = {}
  for _, pos in tree:iter() do
    if pos.type == 'test' then
      tests[#tests + 1] = pos.id
    end
  end
  return {
    command = {},
    context = { build_failure = failure, tests = tests },
    strategy = function()
      return {
        is_complete = function()
          return true
        end,
        result = function()
          return 1
        end,
        output = function()
          return failure.output
        end,
        stop = function() end,
        attach = function()
          vim.cmd('copen')
        end,
      }
    end,
  }
end
return M
