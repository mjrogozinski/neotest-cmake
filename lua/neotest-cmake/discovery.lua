local M = {}
local function read(path)
  local fd = io.open(path, 'rb')
  if not fd then return nil end
  local text = fd:read('*a'); fd:close(); return text
end
M.read = read
function M.join(root, path)
  return vim.fs.normalize(path:match('^/') and path or root .. '/' .. path)
end
function M.framework(command, overrides, cwd)
  local exe = command and command[1]
  if not exe then return nil end
  local explicit = overrides[exe] or overrides[vim.fs.basename(exe)]
  if explicit then return explicit ~= 'ctest' and explicit or nil end
  exe = M.join(cwd, exe)
  local file = io.open(exe, 'rb')
  if not file then return nil end
  local tail, found = '', nil
  -- Inspect signatures, never run an unknown executable just to probe its CLI.
  for _ = 1, 1024 do
    local chunk = file:read(65536)
    if not chunk then break end
    local text = tail .. chunk
    if text:find('gtest_list_tests', 1, true) then found = 'gtest'; break end
    tail = text:sub(-64)
  end
  file:close()
  return found
end
return M
