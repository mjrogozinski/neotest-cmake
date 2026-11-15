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
    -- Static builds contain the flag string. Shared builds (notably Nix)
    -- instead retain their GoogleTest library dependency names in the binary.
    if text:find('gtest_list_tests', 1, true)
      or text:match('libgtest[^%z/%s]*%.dylib')
      or text:match('libgtest[^%z/%s]*%.so')
      or text:match('gtest[^%z/%s]*%.dll') then
      found = 'gtest'; break
    end
    tail = text:sub(-64)
  end
  file:close()
  return found
end
function M.targets(build, config)
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
        if target then
          target.files, target.executables = {}, {}
          for _, source in ipairs(target.sources or {}) do
            local basepath = source.isGenerated and model.paths.build or model.paths.source
            target.files[M.join(basepath, source.path)] = true
          end
          if target.type == 'EXECUTABLE' then
            for _, artifact in ipairs(target.artifacts or {}) do
              target.executables[#target.executables + 1] = M.join(build, artifact.path)
            end
          end
          out[#out + 1] = target
        end
      end
      if not config or config == '' then break end
    end
  end
  return out
end
function M.artifacts(build, config)
  local out = {}
  for _, target in ipairs(M.targets(build, config)) do
    vim.list_extend(out, target.executables)
  end
  return out
end

-- Include executables linking a library that owns a selected source file.
function M.selected_targets(build, config, files)
  local targets, by_id, selected = M.targets(build, config), {}, {}
  for _, target in ipairs(targets) do by_id[target.id] = target end
  local function owns(target, seen)
    if seen[target.id] then return false end
    seen[target.id] = true
    for path in pairs(files) do if target.files[path] then return true end end
    for _, dep in ipairs(target.dependencies or {}) do
      if by_id[dep.id] and owns(by_id[dep.id], seen) then return true end
    end
    return false
  end
  for _, target in ipairs(targets) do
    if #target.executables > 0 and owns(target, {}) then selected[#selected + 1] = target end
  end
  return selected
end
return M
