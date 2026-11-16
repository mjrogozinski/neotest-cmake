local M = {}
local definitions_query
local function query()
  if not definitions_query then
    definitions_query = vim.treesitter.query.parse('cpp', [[
      ((function_definition
        declarator: (function_declarator
          declarator: (_) @kind
          parameters: (parameter_list) @parameters)) @definition
      (#any-of? @kind "TEST" "TEST_F" "TEST_P" "TYPED_TEST" "TYPED_TEST_P"))
    ]])
  end
  return definitions_query
end

-- Tree-sitter owns source detection; runtime enumeration owns parameter names.
function M.definitions(path)
  require('nio').scheduler()
  local text = require('neotest.lib').files.read(path)
  require('nio').scheduler()
  local parser = vim.treesitter.get_string_parser(text, 'cpp', { injections = { cpp = '' } })
  local root = parser:parse()[1]:root()
  local file = { id = path, name = vim.fs.basename(path), path = path,
    type = 'file', range = { root:range() } }
  local definitions = {}
  local q = query()
  for _, match in q:iter_matches(root, text, 0, -1) do
    local captures = {}
    for id, nodes in pairs(match) do captures[q.captures[id]] = nodes[1] end
    local names = {}
    for child in captures.parameters:iter_children() do
      if child:type() == 'parameter_declaration' then
        names[#names + 1] = vim.trim(vim.treesitter.get_node_text(child, text))
      end
    end
    if #names == 2 then
      local suite, case = unpack(names)
      definitions[#definitions + 1] = { id = path .. '::' .. suite .. '.' .. case,
        name = suite .. '.' .. case, type = 'test', path = path,
        range = { captures.definition:range() }, suite = suite, case = case,
        kind = vim.treesitter.get_node_text(captures.kind, text) }
    end
  end
  return file, definitions
end

function M.matches(pos, key)
  if pos.key then return pos.key == key end
  local dot = key:find('.', 1, true)
  if not dot then return false end
  local suite, case = key:sub(1, dot - 1), key:sub(dot + 1)
  local suites = vim.split(suite, '/', { plain = true })
  local cases = vim.split(case, '/', { plain = true })
  if pos.kind == 'TEST_P' then
    return ((#suites == 1 and suites[1] == pos.suite) or (#suites == 2 and suites[2] == pos.suite))
      and #cases == 2 and cases[1] == pos.case
  elseif pos.kind == 'TYPED_TEST' then
    return #suites == 2 and suites[1] == pos.suite and case == pos.case
  elseif pos.kind == 'TYPED_TEST_P' then
    return #suites == 3 and suites[2] == pos.suite and case == pos.case
  end
  return suite == pos.suite and case == pos.case
end

function M.tree(file, definitions, keys)
  if #definitions == 0 then return nil end
  local list = { file }
  for _, pos in ipairs(definitions) do
    if pos.kind == 'TEST_P' or pos.kind == 'TYPED_TEST' or pos.kind == 'TYPED_TEST_P' then
      local group = vim.deepcopy(pos)
      group.type = 'namespace'
      local children, seen = { group }, {}
      for _, key in ipairs(keys) do
        if not seen[key.key] and M.matches(pos, key.key) then
          seen[key.key] = true
          local child = vim.deepcopy(pos)
          -- The definition owns the aggregate source status. Concrete instances
          -- inherit its range for navigation without placing overlapping signs.
          child.range = nil
          child.id, child.name, child.key = file.path .. '::' .. key.key, key.key, key.key
          children[#children + 1] = child
        end
      end
      -- An unbuilt definition stays selectable; the first run builds it.
      if #children == 1 then list[#list + 1] = pos else list[#list + 1] = children end
    else
      list[#list + 1] = pos
    end
  end
  return require('neotest.types').Tree.from_list(list, function(pos) return pos.id end)
end
return M
