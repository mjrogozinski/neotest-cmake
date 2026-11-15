local M = {}
local function read(path)
  local fd = io.open(path, 'rb')
  if not fd then return nil end
  local text = fd:read('*a'); fd:close(); return text
end
M.read = read
function M.json(path)
  local text = read(path)
  if not text then return nil end
  local ok, data = pcall(vim.json.decode, text)
  return ok and data or nil
end
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
function M.artifacts(build, config)
  local base = build .. '/.cmake/api/v1/reply/'
  local indexes = vim.fn.glob(base .. 'index-*.json', false, true)
  table.sort(indexes)
  local index = M.json(indexes[#indexes] or '')
  if not index then return {} end
  local modelref = index.reply and index.reply['codemodel-v2']
  local model = modelref and M.json(base .. modelref.jsonFile)
  if not model then return {} end
  local out = {}
  for _, cfg in ipairs(model.configurations or {}) do
    if not config or config == '' or cfg.name == config then
      for _, ref in ipairs(cfg.targets or {}) do
        local target = M.json(base .. ref.jsonFile)
        if target and target.type == 'EXECUTABLE' then
          for _, artifact in ipairs(target.artifacts or {}) do out[#out + 1] = M.join(build, artifact.path) end
        end
      end
      if not config or config == '' then break end
    end
  end
  return out
end
return M
