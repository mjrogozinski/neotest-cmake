local M = {}
local active = {}

-- Counts overlap: a refresh can enumerate binaries while source workers parse.
function M.with(root, callback)
  if not root then return callback() end
  active[root] = (active[root] or 0) + 1
  local result = { pcall(callback) }
  active[root] = active[root] - 1
  if active[root] == 0 then active[root] = nil end
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2)
end

function M.blocked(args)
  args = type(args) == 'string' and { args } or args or {}
  if args.adapter and not vim.startswith(args.adapter, 'neotest-cmake:') then return false end
  local path = args[1] or vim.api.nvim_buf_get_name(0)
  path = path ~= '' and vim.fs.normalize(path) or vim.uv.cwd()
  local root = args.adapter and args.adapter:sub(#'neotest-cmake:' + 1)
  for project in pairs(active) do
    if root == project or (not root and (path == project or vim.startswith(path, project .. '/')
      or vim.startswith(path, project .. '::'))) then
      vim.notify('CMake test discovery is still in progress. Please wait, then run tests again.', vim.log.levels.INFO)
      return true
    end
  end
  return false
end
return M
