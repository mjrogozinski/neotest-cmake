local M = {}
local kinds = { TEST = true, TEST_F = true, TEST_P = true, TYPED_TEST = true, TYPED_TEST_P = true }

function M.discover(path)
  require('nio').scheduler()
  local text = require('neotest.lib').files.read(path)
  require('nio').scheduler()
  local parser = vim.treesitter.get_string_parser(text, 'cpp', { injections = { cpp = '' } })
  local root = parser:parse()[1]:root()
  local list = { { id = path, name = vim.fs.basename(path), path = path,
    type = 'file', range = { root:range() } } }
  -- Traverse definitions rather than matching text inside comments or strings.
  local function visit(node)
    if node:type() == 'function_definition' then
      local decl = node:field('declarator')[1]
      local name = decl and decl:field('declarator')[1]
      local params = decl and decl:field('parameters')[1]
      local kind = name and vim.treesitter.get_node_text(name, text)
      if kinds[kind] and params then
        local names = {}
        for child in params:iter_children() do
          if child:type() == 'parameter_declaration' then
            names[#names + 1] = vim.trim(vim.treesitter.get_node_text(child, text))
          end
        end
        if #names == 2 and names[1]:match('^[_%a][_%w]*$') and names[2]:match('^[_%a][_%w]*$') then
          local suite, case = unpack(names)
          list[#list + 1] = { id = path .. '::' .. suite .. '.' .. case,
            name = suite .. '.' .. case, type = 'test', path = path,
            range = { node:range() }, suite = suite, case = case, kind = kind }
        end
      end
    end
    for child in node:iter_children() do visit(child) end
  end
  visit(root)
  if #list == 1 then return nil end
  return require('neotest.types').Tree.from_list(list, function(pos) return pos.id end)
end

local function escape(s) return (s:gsub('([^%w])', '%%%1')) end
function M.matches(pos, key)
  local suite, case = escape(pos.suite), escape(pos.case)
  if pos.kind == 'TEST_P' then
    return key:match('^.-/' .. suite .. '%.' .. case .. '/[^/]+$') ~= nil
  elseif pos.kind == 'TYPED_TEST' then
    return key:match('^' .. suite .. '/[^/]+%.' .. case .. '$') ~= nil
  elseif pos.kind == 'TYPED_TEST_P' then
    return key:match('^.-/' .. suite .. '/[^/]+%.' .. case .. '$') ~= nil
  end
  return key == pos.suite .. '.' .. pos.case
end
return M
