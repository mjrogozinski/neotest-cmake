local discovery = require('neotest-cmake.discovery')
local parsers = require('neotest-cmake.parsers')
local source = require('neotest-cmake.source')
local diagnostics = require('neotest-cmake.diagnostics')
local M = { name = 'neotest-cmake' }
local builds, listings, build_locks = {}, {}, {}
local runner = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/runner.lua'
local opts = { build_dir = 'build', config = '', ctest = 'ctest', discovery_timeout = 10000,
  jobs = 1, frameworks = {}, ctest_args = {}, build = true, cmake = 'cmake', build_timeout = 120000, dap = { type = 'codelldb' } }

local function process(command, cwd, env, timeout)
  local nio = require('nio')
  nio.scheduler()
  local done = nio.control.event()
  local result
  vim.system(command, { cwd = cwd, env = env, text = true, timeout = timeout or opts.discovery_timeout }, function(r)
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
  if builds[root] then return root, builds[root].build_dir, builds[root].config end
  local build = type(opts.build_dir) == 'function' and opts.build_dir(root) or opts.build_dir
  return root, discovery.join(root, build), opts.config
end
function M.root(path)
  local known
  path = vim.fs.normalize(path)
  for root in pairs(builds) do
    if (path == root or path:sub(1, #root + 1) == root .. '/') and (not known or #root > #known) then known = root end
  end
  if known then return known end
  if opts.root then return type(opts.root) == 'function' and opts.root(path) or opts.root end
  return vim.fs.root(path, { 'CMakePresets.json', '.git' }) or vim.fs.root(path, 'CMakeLists.txt')
end
function M.filter_dir(name, relpath, root)
  local build = builds[root] and builds[root].build_dir
    or (type(opts.build_dir) == 'function' and opts.build_dir(root) or opts.build_dir)
  return name ~= '.git' and name ~= 'CMakeFiles' and discovery.join(root, relpath) ~= discovery.join(root, build)
end
function M.is_test_file(path)
  if not vim.tbl_contains({ 'c', 'cc', 'cpp', 'cxx', 'h', 'hpp', 'hxx' }, vim.fn.fnamemodify(path, ':e')) then return false end
  local _, definitions = source.definitions(path)
  return #definitions > 0
end

local function listed(command, cwd, env)
  local exe = discovery.join(cwd, command[1])
  local stat = vim.uv.fs_stat(exe)
  if not stat then return {} end
  local signature = vim.json.encode({ command, cwd, env or {}, stat.size, stat.mtime })
  if listings[signature] then return listings[signature] end
  local r = process(command, cwd, env)
  if r.code ~= 0 then return {} end
  local keys = parsers.gtest_list(r.stdout or '')
  listings[signature] = keys
  return keys
end

local function registrations(build, config)
  local command = { opts.ctest, '--test-dir', build, '--show-only=json-v1' }
  if config ~= '' then vim.list_extend(command, { '-C', config }) end
  local r = process(command, build)
  assert(r.code == 0, 'neotest-cmake: CTest discovery failed: ' .. (r.stderr or ''))
  local data = vim.json.decode(r.stdout)
  local out, covered = {}, {}
  for _, test in ipairs(data.tests or {}) do
    local props = {}
    for _, p in ipairs(test.properties or {}) do props[p.name] = p.value end
    local cwd = props.WORKING_DIRECTORY or build
    for _, arg in ipairs(test.command or {}) do
      local path = discovery.join(cwd, arg)
      covered[vim.uv.fs_realpath(path) or path] = true
    end
    local keys = {}
    if discovery.framework(test.command, opts.frameworks, cwd) == 'gtest' then
      local command, env = vim.deepcopy(test.command), {}
      -- Keep the registration's existing filter and arguments when enumerating.
      command[#command + 1] = '--gtest_list_tests'
      for _, entry in ipairs(props.ENVIRONMENT or {}) do
        local k, v = entry:match('^([^=]+)=(.*)$')
        if k then env[k] = v end
      end
      keys = listed(command, cwd, env)
    end
    out[#out + 1] = { name = test.name, keys = keys, disabled = props.DISABLED,
      binary = test.command and test.command[1], command = test.command, cwd = cwd, properties = props }
  end
  -- The same File API fallback as cmake-tests.nvim: executable targets need
  -- not have add_test()/gtest_discover_tests() registrations.
  for _, exe in ipairs(discovery.artifacts(build, config)) do
    local path = vim.uv.fs_realpath(exe) or exe
    if not covered[path] and discovery.framework({ exe }, opts.frameworks, build) == 'gtest' then
      covered[path] = true
      out[#out + 1] = { name = exe, executable = exe, keys = listed({ exe, '--gtest_list_tests' }, build) }
    end
  end
  return out
end

local function for_files(entries, build, config, files)
  local targets = discovery.selected_targets(build, config, files)
  if #discovery.targets(build, config) == 0 then return entries end
  local binaries, out = {}, {}
  for _, target in ipairs(targets) do
    for _, exe in ipairs(target.executables) do binaries[vim.uv.fs_realpath(exe) or exe] = true end
  end
  for _, entry in ipairs(entries) do
    local exe = entry.executable or entry.binary
    if exe then
      exe = discovery.join(build, exe)
      if binaries[vim.uv.fs_realpath(exe) or exe] then out[#out + 1] = entry end
    end
  end
  return out
end

function M.discover_positions(path)
  local file, definitions = source.definitions(path)
  if #definitions == 0 then return nil end
  local _, build, config = paths(path)
  local keys = {}
  if vim.uv.fs_stat(build .. '/CMakeCache.txt') then
    for _, entry in ipairs(for_files(registrations(build, config), build, config, { [path] = true })) do
      vim.list_extend(keys, entry.keys)
    end
  end
  return source.tree(file, definitions, keys)
end

local function build_selected(root, build, config, files)
  if opts.build == false then return true end
  local nio = require('nio')
  build_locks[build] = build_locks[build] or nio.control.semaphore(1)
  local failure
  build_locks[build].with(function()
    if not vim.uv.fs_stat(build .. '/CMakeCache.txt') then
      failure = diagnostics.report(root, build, 'configure', {
        code = 1, stderr = 'Configure the CMake build first: ' .. build })
      return
    end
    if #discovery.targets(build, config) == 0 then
      local query = build .. '/.cmake/api/v1/query'
      vim.fn.mkdir(query, 'p')
      vim.fn.writefile({}, query .. '/codemodel-v2')
      local r = process({ opts.cmake, '-S', root, '-B', build }, root, nil, opts.build_timeout)
      if r.code ~= 0 then failure = diagnostics.report(root, build, 'configure', r); return end
    end
    local targets = discovery.selected_targets(build, config, files)
    if #targets == 0 then
      failure = diagnostics.report(root, build, 'configure', {
        code = 1, stderr = 'No executable target owns the selected test sources in ' .. build })
      return
    end
    local command = { opts.cmake, '--build', build }
    if config ~= '' then vim.list_extend(command, { '--config', config }) end
    command[#command + 1] = '--target'
    for _, target in ipairs(targets) do command[#command + 1] = target.name end
    local r = process(command, root, nil, opts.build_timeout)
    if r.code ~= 0 then failure = diagnostics.report(root, build, 'build', r); return end
    listings = {}
    diagnostics.clear(root, build)
  end)
  return not failure, failure
end

-- Called after an external CMake build, including preset/external build trees.
-- Preserve each project's context rather than changing global adapter options.
function M.discover(context)
  require('nio').scheduler()
  local root = vim.uv.fs_realpath(context.root) or vim.fs.normalize(context.root)
  local build = discovery.join(root, context.build_dir)
  local config = context.config or opts.config
  local artifacts = discovery.artifacts(build, config)
  assert(#artifacts > 0, 'neotest-cmake: no executable targets in CMake File API reply at ' .. build)
  local entries = registrations(build, config)
  local binaries, count = {}, 0
  for _, entry in ipairs(entries) do
    if #entry.keys > 0 then
      for _, case in ipairs(entry.keys) do
        local binary = entry.executable or entry.binary or entry.name
        binaries[binary] = binaries[binary] or {}
        if not binaries[binary][case.key] then binaries[binary][case.key] = true; count = count + 1 end
      end
    end
  end
  builds[root] = { build_dir = build, config = config }
  return { root = root, build_dir = build, config = config, binaries = vim.tbl_count(binaries), cases = count }
end
local function regex(s) return (s:gsub('([\\%.%[%]%^%$%*%+%?%(%){|}])', '\\%1')) end

function M.prepare(tree)
  local root, build, config = paths(tree:data().path)
  local files = {}
  for _, node in tree:iter_nodes() do
    local pos = node:data()
    if pos.type == 'test' or pos.type == 'namespace' then files[pos.path] = true end
  end
  local success, failure = build_selected(root, build, config, files)
  return success and files or nil, build, config, failure
end

function M.build_spec(args)
  local files, build, config, failure = M.prepare(args.tree)
  if not files then return diagnostics.blocked(args.tree, failure) end
  local tests = {}
  for _, node in args.tree:iter_nodes() do
    local pos = node:data()
    if pos.type == 'test' then tests[#tests + 1] = pos end
  end
  assert(#tests > 0, 'neotest-cmake: no GoogleTest source positions selected')
  local selected, mappings, specs, matched, debugging = {}, {}, {}, {}, {}
  for _, reg in ipairs(for_files(registrations(build, config), build, config, files)) do
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
      for id in pairs(ids) do matched[id] = true end
      if args.strategy == 'dap' then
        debugging[#debugging + 1] = { registration = reg, mappings = ids }
      elseif reg.executable then
        local keys, disabled = {}, {}
        for _, key in ipairs(reg.keys) do disabled[key.key] = key.disabled end
        for _, values in pairs(ids) do vim.list_extend(keys, values) end
        table.sort(keys)
        local command = { reg.executable, '--gtest_color=no', '--gtest_filter=' .. table.concat(keys, ':') }
        vim.list_extend(command, args.extra_args or {})
        specs[#specs + 1] = { command = command, cwd = build,
          context = { direct = true, mappings = ids, disabled = disabled, tests = {} } }
      else
        selected[#selected + 1] = regex(reg.name)
        mappings[reg.name] = ids
      end
    end
  end
  if args.strategy == 'dap' then
    assert(#debugging > 0, 'neotest-cmake: no built GoogleTest cases selected for debugging')
    local command, cwd, env, signature, mappings, disabled, keys = nil, nil, nil, nil, {}, {}, {}
    for _, entry in ipairs(debugging) do
      local reg = entry.registration
      local props = reg.properties or {}
      assert(not props.FIXTURES_REQUIRED and not props.FIXTURES_SETUP and not props.FIXTURES_CLEANUP,
        'neotest-cmake: debug runs do not support CTest fixtures; use a normal test run')
      local argv = {}
      for _, arg in ipairs(reg.command or { reg.executable }) do
        if not vim.startswith(arg, '--gtest_filter=') and not vim.startswith(arg, '--gtest_color=') then
          argv[#argv + 1] = arg
        end
      end
      local launch_env = {}
      for _, value in ipairs(props.ENVIRONMENT or {}) do
        local key, val = value:match('^([^=]+)=(.*)$')
        if key then launch_env[key] = val end
      end
      local launch_cwd = reg.cwd or build
      local current = vim.json.encode({ argv, launch_cwd, launch_env })
      assert(not signature or signature == current,
        'neotest-cmake: debug selection must use one executable with one launch environment')
      command, cwd, env, signature = argv, launch_cwd, launch_env, current
      for id, values in pairs(entry.mappings) do
        mappings[id] = mappings[id] or {}
        vim.list_extend(mappings[id], values)
        for _, key in ipairs(values) do keys[key] = true end
      end
      for _, key in ipairs(reg.keys) do disabled[key.key] = key.disabled end
    end
    local filter = vim.tbl_keys(keys)
    table.sort(filter)
    vim.list_extend(command, { '--gtest_color=no', '--gtest_filter=' .. table.concat(filter, ':') })
    vim.list_extend(command, args.extra_args or {})
    local launch = vim.tbl_extend('force', opts.dap, { request = 'launch', name = 'GoogleTest',
      program = command[1], args = vim.list_slice(command, 2), cwd = cwd, env = env })
    return { command = command, cwd = cwd, env = env, strategy = launch,
      context = { direct = true, mappings = mappings, disabled = disabled, tests = {} } }
  end
  if #selected > 0 then
    local report = vim.fn.tempname() .. '.xml'
    local command = { opts.ctest, '--test-dir', build, '--output-on-failure',
      '--output-junit', report, '--parallel', tostring(opts.jobs), '-R', '^(' .. table.concat(selected, '|') .. ')$' }
    if config ~= '' then vim.list_extend(command, { '-C', config }) end
    vim.list_extend(command, opts.ctest_args)
    vim.list_extend(command, args.extra_args or {})
    table.insert(specs, 1, { command = command, cwd = build, context = { report = report, mappings = mappings, tests = {} } })
  end
  assert(#specs > 0, 'neotest-cmake: no matching test executables in ' .. build
    .. '; build first. For unregistered targets, create build/.cmake/api/v1/query/codemodel-v2 and reconfigure CMake (or use <leader>iB in the installed config).')
  -- Neotest merges results from multiple specs. Only one spec reports each
  -- unmatched source definition, so a skip cannot overwrite another run's pass.
  for _, pos in ipairs(tests) do
    if not matched[pos.id] then specs[1].context.tests[#specs[1].context.tests + 1] = pos end
  end
  if #specs == 1 then return specs[1] end
  -- Older neotest runners share process keys/output paths across specs for a
  -- single tree. Use one strategy process and execute its argv lists in order.
  local manifest = vim.fn.tempname() .. '.json'
  local commands = {}
  for _, spec in ipairs(specs) do
    spec.context.output = vim.fn.tempname()
    commands[#commands + 1] = { command = spec.command, cwd = spec.cwd, output = spec.context.output }
  end
  vim.fn.writefile({ vim.json.encode(commands) }, manifest)
  return { command = { vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-l', runner, manifest },
    cwd = build, context = { runs = specs, manifest = manifest } }
end

function M.results(spec, result)
  if spec.context.build_failure then
    local out = {}
    for _, id in ipairs(spec.context.tests) do
      out[id] = { status = 'skipped', output = spec.context.build_failure.output,
        short = spec.context.build_failure.summary .. '; see quickfix' }
    end
    return out
  end
  if spec.context.runs then
    local out = {}
    for _, run in ipairs(spec.context.runs) do
      local collected = M.results(run, { code = result.code, output = run.context.output })
      for id, value in pairs(collected) do
        value.output = result.output
        -- A source definition can be compiled into more than one binary.
        local rank = { skipped = 1, passed = 2, failed = 3 }
        if not out[id] or rank[value.status] > rank[out[id].status] then out[id] = value end
      end
      os.remove(run.context.output)
    end
    os.remove(spec.context.manifest)
    return out
  end
  local xml = spec.context.report and discovery.read(spec.context.report)
  local out, seen, rank = {}, {}, { skipped = 1, passed = 2, failed = 3 }
  local function add(id, status, message)
    if not out[id] or rank[status] > rank[out[id].status] then
      out[id] = { status = status, output = result.output, short = message }
    end
  end
  if spec.context.direct then
    local text = discovery.read(result.output) or ''
    local cases = {}
    for _, case in ipairs(parsers.results(text)) do cases[case.key] = case end
    for id, keys in pairs(spec.context.mappings) do
      for _, key in ipairs(keys) do
        local case = cases[key]
        add(id, case and case.status or spec.context.disabled[key] and 'skipped' or 'failed',
          case and case.output or 'No result for ' .. key .. '; inspect process output')
      end
    end
    for _, pos in ipairs(spec.context.tests) do add(pos.id, 'skipped', 'No matching built test') end
    return out
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
    if not out[pos.id] then add(pos.id, 'skipped', 'No matching built test') end
  end
  if xml then os.remove(spec.context.report) end
  return out
end

return setmetatable(M, { __call = function(_, config)
  opts = vim.tbl_deep_extend('force', opts, config or {})
  return M
end })
