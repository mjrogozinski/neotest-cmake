local discovery = require('neotest-cmake.discovery')
local parsers = require('neotest-cmake.parsers')
local source = require('neotest-cmake.source')
local diagnostics = require('neotest-cmake.diagnostics')
local M = { name = 'neotest-cmake' }
local builds, listings, build_locks, position_keys, unbuilt = {}, {}, {}, {}, {}
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

local function registrations(build, config, selection)
  local allowed = selection and selection.executables
  local function selected(exe, cwd)
    if not exe then return false end
    exe = discovery.join(cwd, exe)
    return not allowed or allowed[vim.uv.fs_realpath(exe) or exe]
  end
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
    local env = {}
    for _, entry in ipairs(props.ENVIRONMENT or {}) do
      local k, v = entry:match('^([^=]+)=(.*)$')
      if k then env[k] = v end
    end
    if selected(test.command and test.command[1], cwd) and discovery.framework(test.command, opts.frameworks, cwd) == 'gtest' then
      local command = vim.deepcopy(test.command)
      -- Keep the registration's existing filter and arguments when enumerating.
      command[#command + 1] = '--gtest_list_tests'
      out[#out + 1] = { kind = 'ctest', name = test.name, keys = listed(command, cwd, env),
        executable = discovery.join(cwd, test.command[1]), command = test.command, cwd = cwd, env = env, properties = props }
    end
  end
  -- The same File API fallback as cmake-tests.nvim: executable targets need
  -- not have add_test()/gtest_discover_tests() registrations.
  for _, exe in ipairs(discovery.artifacts(build, config)) do
    local path = vim.uv.fs_realpath(exe) or exe
    if selected(exe, build) and not covered[path] and discovery.framework({ exe }, opts.frameworks, build) == 'gtest' then
      covered[path] = true
      out[#out + 1] = { kind = 'direct', name = exe, executable = exe, command = { exe }, cwd = build, env = {}, properties = {},
        keys = listed({ exe, '--gtest_list_tests' }, build) }
    end
  end
  return out
end

function M.discover_positions(path)
  local file, definitions = source.definitions(path)
  if #definitions == 0 then return nil end
  local _, build, config = paths(path)
  local key = build .. '\0' .. config .. '\0' .. path
  local cached = position_keys[key]
  local keys = cached and cached.keys or {}
  local selection = discovery.select(build, config, { [path] = true })
  local fresh, stamp = #selection.targets > 0 and not (unbuilt[build] or {})[path], {}
  for _, target in ipairs(selection.targets) do
    for _, exe in ipairs(target.executables) do
      local binary = vim.uv.fs_stat(exe)
      stamp[#stamp + 1] = binary and binary.mtime or false
      for source in pairs(target.files) do
        local input = vim.uv.fs_stat(source)
        if not binary or not input or input.mtime.sec > binary.mtime.sec
          or (input.mtime.sec == binary.mtime.sec and input.mtime.nsec > binary.mtime.nsec) then fresh = false end
      end
    end
  end
  stamp = vim.json.encode(stamp)
  -- Editing/saving a file must not launch its old binary just to rediscover
  -- parameter names. Keep known names until a successful build changes it.
  if (opts.build == false or fresh) and (not cached or cached.stamp ~= stamp) then
    keys = {}
    if vim.uv.fs_stat(build .. '/CMakeCache.txt') then
      for _, entry in ipairs(registrations(build, config, selection)) do
        vim.list_extend(keys, entry.keys)
      end
    end
    position_keys[key] = { stamp = stamp, keys = keys }
  end
  return source.tree(file, definitions, keys)
end

local function build_selected(root, build, config, files, selection)
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
    local targets = (#selection.model > 0 and selection or discovery.select(build, config, files)).targets
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
        local binary = entry.executable
        binaries[binary] = binaries[binary] or {}
        if not binaries[binary][case.key] then binaries[binary][case.key] = true; count = count + 1 end
      end
    end
  end
  unbuilt[build] = nil
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
  local selection = discovery.select(build, config, files)
  local affected = selection.affected
  unbuilt[build] = unbuilt[build] or {}
  for path in pairs(affected) do unbuilt[build][path] = true end
  local success, failure = build_selected(root, build, config, files, selection)
  for path in pairs(affected) do unbuilt[build][path] = not success or nil end
  if failure then failure.files = affected end
  return success and files or nil, build, config, failure, selection
end

function M.build_spec(args)
  local files, build, config, failure, selection = M.prepare(args.tree)
  if not files then return diagnostics.blocked(args.tree, failure) end
  local tests = {}
  for _, node in args.tree:iter_nodes() do
    local pos = node:data()
    if pos.type == 'test' then tests[#tests + 1] = pos end
  end
  assert(#tests > 0, 'neotest-cmake: no GoogleTest source positions selected')
  local selected, mappings, specs, matched, debugging = {}, {}, {}, {}, {}
  for _, reg in ipairs(registrations(build, config, selection)) do
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
      elseif reg.kind == 'direct' then
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
      local props = reg.properties
      assert(not props.FIXTURES_REQUIRED and not props.FIXTURES_SETUP and not props.FIXTURES_CLEANUP,
        'neotest-cmake: debug runs do not support CTest fixtures; use a normal test run')
      local argv = {}
      for _, arg in ipairs(reg.command) do
        if not vim.startswith(arg, '--gtest_filter=') and not vim.startswith(arg, '--gtest_color=') then
          argv[#argv + 1] = arg
        end
      end
      local launch_env, launch_cwd = reg.env, reg.cwd
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
      '--output-junit', report, '--test-output-size-passed', '0', '--test-output-size-failed', '0',
      '--parallel', tostring(opts.jobs), '-R', '^(' .. table.concat(selected, '|') .. ')$' }
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

M.results = require('neotest-cmake.results').collect

return setmetatable(M, { __call = function(_, config)
  opts = vim.tbl_deep_extend('force', opts, config or {})
  return M
end })
