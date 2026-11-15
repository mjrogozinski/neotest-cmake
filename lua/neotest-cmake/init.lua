local discovery = require('neotest-cmake.discovery')
local parsers = require('neotest-cmake.parsers')
local source = require('neotest-cmake.source')
local M = { name = 'neotest-cmake' }
local opts = { build_dir = 'build', config = '', ctest = 'ctest', discovery_timeout = 10000,
  jobs = 1, frameworks = {}, ctest_args = {} }

local function process(command, cwd, env)
  local nio = require('nio')
  nio.scheduler()
  local done = nio.control.event()
  local result
  vim.system(command, { cwd = cwd, env = env, text = true, timeout = opts.discovery_timeout }, function(r)
    result = r
    done.set()
  end)
  done.wait()
  nio.scheduler()
  return result
end
local function paths(path)
  local root = M.root(path)
  assert(root, 'neotest-cmake: no CMake project root found')
  local build = type(opts.build_dir) == 'function' and opts.build_dir(root) or opts.build_dir
  return root, discovery.join(root, build)
end
function M.root(path)
  if opts.root then return type(opts.root) == 'function' and opts.root(path) or opts.root end
  return vim.fs.root(path, { 'CMakePresets.json', '.git' }) or vim.fs.root(path, 'CMakeLists.txt')
end
function M.filter_dir(name, relpath, root)
  local build = type(opts.build_dir) == 'function' and opts.build_dir(root) or opts.build_dir
  return name ~= '.git' and name ~= 'CMakeFiles' and discovery.join(root, relpath) ~= discovery.join(root, build)
end
function M.is_test_file(path)
  if not path:match('%.c[cp]*$') and not path:match('%.cxx$') and not path:match('%.h[px]*$') then return false end
  local text = discovery.read(path)
  return text ~= nil and text:match('%f[%w]T[%u_]*TEST[%u_]*%s*%(') ~= nil
    or text ~= nil and text:match('%f[%w]TEST[%u_]*%s*%(') ~= nil
end
M.discover_positions = source.discover

local function registrations(build)
  local command = { opts.ctest, '--test-dir', build, '--show-only=json-v1' }
  if opts.config ~= '' then vim.list_extend(command, { '-C', opts.config }) end
  local r = process(command, build)
  assert(r.code == 0, 'neotest-cmake: CTest discovery failed: ' .. (r.stderr or ''))
  local data = vim.json.decode(r.stdout)
  local out = {}
  for _, test in ipairs(data.tests or {}) do
    local props = {}
    for _, p in ipairs(test.properties or {}) do props[p.name] = p.value end
    local cwd = props.WORKING_DIRECTORY or build
    local keys = {}
    if discovery.framework(test.command, opts.frameworks, cwd) == 'gtest' then
      local command, env = vim.deepcopy(test.command), {}
      -- Keep the registration's existing filter and arguments when enumerating.
      command[#command + 1] = '--gtest_list_tests'
      for _, entry in ipairs(props.ENVIRONMENT or {}) do
        local k, v = entry:match('^([^=]+)=(.*)$')
        if k then env[k] = v end
      end
      local listed = process(command, cwd, env)
      if listed.code == 0 then keys = parsers.gtest_list(listed.stdout or '') end
    end
    out[#out + 1] = { name = test.name, keys = keys, disabled = props.DISABLED }
  end
  return out
end
local function regex(s) return (s:gsub('([\\%.%[%]%^%$%*%+%?%(%){|}])', '\\%1')) end

function M.build_spec(args)
  assert(args.strategy ~= 'dap', 'neotest-cmake: CTest does not support the dap strategy')
  local _, build = paths(args.tree:data().path)
  local tests = {}
  for _, node in args.tree:iter_nodes() do
    local pos = node:data()
    if pos.type == 'test' then tests[#tests + 1] = pos end
  end
  assert(#tests > 0, 'neotest-cmake: no GoogleTest source positions selected')
  local selected, mappings = {}, {}
  for _, reg in ipairs(registrations(build)) do
    local ids = {}
    for _, pos in ipairs(tests) do
      for _, key in ipairs(reg.keys) do
        if source.matches(pos, key.key) then
          ids[pos.id] = ids[pos.id] or {}
          ids[pos.id][#ids[pos.id] + 1] = key.key
        end
      end
    end
    if next(ids) then
      selected[#selected + 1] = regex(reg.name)
      mappings[reg.name] = ids
    end
  end
  assert(#selected > 0, 'neotest-cmake: no matching CTest registrations; configure/build first and register tests with CTest')
  local report = vim.fn.tempname() .. '.xml'
  local command = { opts.ctest, '--test-dir', build, '--output-on-failure',
    '--output-junit', report, '--parallel', tostring(opts.jobs), '-R', '^(' .. table.concat(selected, '|') .. ')$' }
  if opts.config ~= '' then vim.list_extend(command, { '-C', opts.config }) end
  vim.list_extend(command, opts.ctest_args)
  vim.list_extend(command, args.extra_args or {})
  return { command = command, cwd = build, context = { report = report, mappings = mappings, tests = tests } }
end

function M.results(spec, result)
  local xml = discovery.read(spec.context.report)
  local out, seen, rank = {}, {}, { skipped = 1, passed = 2, failed = 3 }
  local function add(id, status, message)
    if not out[id] or rank[status] > rank[out[id].status] then
      out[id] = { status = status, output = result.output, short = message }
    end
  end
  for _, row in ipairs(parsers.junit(xml or '')) do
    seen[row.name] = true
    local cases = {}
    for _, case in ipairs(parsers.results(row.output)) do cases[case.key] = case end
    for id, keys in pairs(spec.context.mappings[row.name] or {}) do
      for _, key in ipairs(keys) do
        local case = cases[key]
        local status = row.status
        if case then
          -- CTest owns registration policy (including WILL_FAIL and skip rules).
          if row.status == 'failed' then status = case.status
          elseif row.status == 'passed' and case.status == 'skipped' then status = 'skipped' end
        elseif row.status == 'passed' then
          status = 'skipped' -- listed but disabled/not executed
        end
        add(id, status, case and case.output or row.output)
      end
    end
  end
  -- An absent report/entry is a failed or interrupted run, never an inferred pass.
  for name, ids in pairs(spec.context.mappings) do
    for id in pairs(ids) do
      if not seen[name] then add(id, 'failed', 'CTest did not produce a result for ' .. name .. '; inspect process output') end
    end
  end
  for _, pos in ipairs(spec.context.tests) do
    if not out[pos.id] then add(pos.id, 'skipped', 'No matching CTest registration') end
  end
  if xml then os.remove(spec.context.report) end
  return out
end

return setmetatable(M, { __call = function(_, config)
  opts = vim.tbl_deep_extend('force', opts, config or {})
  return M
end })
