local M = {}

-- A cache belongs to its original build tree. Seed a new tree with public
-- options only; let CMake regenerate its internal and computed directory data.
local function bracket(value)
  local equals = ''
  while value:find(']' .. equals .. ']', 1, true) do
    equals = equals .. '='
  end
  return '[' .. equals .. '[' .. value .. ']' .. equals .. ']'
end

function M.configure(command, source, build)
  local entries, generator = {}, {}
  for _, line in ipairs(vim.fn.readfile(source .. '/CMakeCache.txt')) do
    local name, kind, value = line:match('^([^#/:][^:]*):([A-Z_]+)=(.*)$')
    if name then
      if name == 'CMAKE_GENERATOR' then
        generator.name = value
      elseif name == 'CMAKE_GENERATOR_PLATFORM' then
        generator.platform = value
      elseif name == 'CMAKE_GENERATOR_TOOLSET' then
        generator.toolset = value
      elseif
        kind ~= 'INTERNAL'
        and kind ~= 'STATIC'
        and name ~= 'CMAKE_BUILD_TYPE'
        and name ~= 'CMAKE_FIND_PACKAGE_REDIRECTS_DIR'
        and not name:match('_BINARY_DIR$')
        and not name:match('_SOURCE_DIR$')
      then
        -- Keep paths into generated dependencies inside the isolated tree too.
        value = value:gsub(vim.pesc(source), function()
          return build
        end)
        entries[#entries + 1] = 'set(' .. bracket(name) .. ' ' .. bracket(value) .. ' CACHE ' .. kind .. ' "" FORCE)'
      end
    end
  end
  local seed = build .. '/neotest-cache.cmake'
  vim.fn.writefile(entries, seed)
  vim.list_extend(command, { '-C', seed })
  for _, item in ipairs({ { '-G', generator.name }, { '-A', generator.platform }, { '-T', generator.toolset } }) do
    if item[2] and item[2] ~= '' then
      vim.list_extend(command, item)
    end
  end
end

return M
