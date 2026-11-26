local discovery = require('neotest-cmake.discovery')
local parsers = require('neotest-cmake.parsers')
local diagnostics = require('neotest-cmake.diagnostics')
local M = {}
local configured_options = {
  build_dir = 'build',
  config = '',
  ctest = 'ctest',
  discovery_timeout = 10000,
  jobs = 1,
  frameworks = {},
  ctest_args = {},
  build = true,
  cmake = 'cmake',
  build_timeout = 120000,
  dap = { type = 'codelldb' },
}
local builds, states = {}, {}

---@param config? neotest-cmake.Options
function M.configure(config)
  configured_options = vim.tbl_deep_extend('force', configured_options, config or {})
end

--- Return a copy of the configured options without resolving or building a project.
---@return neotest-cmake.Options
function M.options()
  return vim.deepcopy(configured_options)
end

---@param path string
---@return string?
function M.root(path)
  local known
  path = vim.fs.normalize(path)
  for root in pairs(builds) do
    if (path == root or path:sub(1, #root + 1) == root .. '/') and (not known or #root > #known) then
      known = root
    end
  end
  if known then
    return known
  end
  if configured_options.root then
    return type(configured_options.root) == 'function' and configured_options.root(path) or configured_options.root
  end
  return vim.fs.root(path, { 'CMakePresets.json', '.git' }) or vim.fs.root(path, 'CMakeLists.txt')
end

local function context(root, build, config)
  build = discovery.join(root, build)
  local state = states[build]
  if not state then
    state = { lock = require('nio').control.semaphore(1), configurations = {} }
    states[build] = state
  end
  state.configurations[config] = state.configurations[config] or { listings = {}, keys = {}, unbuilt = {} }
  return {
    root = root,
    build_dir = build,
    config = config,
    options = configured_options,
    state = state.configurations[config],
    lock = state.lock,
  }
end

---@param path string
---@return neotest-cmake.BuildContext
function M.context(path)
  local root = assert(M.root(path), 'neotest-cmake: no CMake project root found')
  local selected = builds[root]
  return context(
    root,
    selected and selected.build_dir
      or (
        type(configured_options.build_dir) == 'function' and configured_options.build_dir(root)
        or configured_options.build_dir
      ),
    selected and selected.config or configured_options.config
  )
end

local function process(ctx, command, cwd, env, timeout)
  local nio = require('nio')
  nio.scheduler()
  local done, result = nio.control.event(), nil
  vim.system(
    command,
    { cwd = cwd, env = env, text = true, timeout = timeout or ctx.options.discovery_timeout },
    function(r)
      result = r
      done.set()
    end
  )
  done.wait()
  nio.scheduler()
  return result
end

local function select(ctx, files)
  local selection = discovery.select(ctx.build_dir, ctx.config, files)
  selection.context = ctx
  return selection
end

function M.files(tree)
  local files = {}
  for _, pos in tree:iter() do
    if pos.type == 'test' or pos.type == 'namespace' then
      files[pos.path] = true
    end
  end
  return files
end

local function listed(ctx, command, cwd, env)
  local stat = vim.uv.fs_stat(discovery.join(cwd, command[1]))
  if not stat then
    return {}
  end
  local signature = vim.json.encode({ command, cwd, env, stat.size, stat.mtime })
  local cache = ctx.state.listings
  if cache[signature] then
    return cache[signature]
  end
  local result = process(ctx, command, cwd, env)
  if result.code ~= 0 then
    return {}
  end
  cache[signature] = parsers.gtest_list(result.stdout or '')
  return cache[signature]
end

---@param selection neotest-cmake.Selection
---@return neotest-cmake.Registration[]
function M.registrations(selection)
  local ctx = selection.context
  local build, config, opts = ctx.build_dir, ctx.config, ctx.options
  local allowed = selection.executables
  local function selected(exe, cwd)
    if not exe then
      return false
    end
    exe = discovery.join(cwd, exe)
    return not allowed or allowed[vim.uv.fs_realpath(exe) or exe]
  end
  local listing_command = { opts.ctest, '--test-dir', build, '--show-only=json-v1' }
  if config ~= '' then
    vim.list_extend(listing_command, { '-C', config })
  end
  local r = process(ctx, listing_command, build)
  assert(r.code == 0, 'neotest-cmake: CTest discovery failed: ' .. (r.stderr or ''))
  local data = vim.json.decode(r.stdout)
  local out, covered = {}, {}
  for _, test in ipairs(data.tests or {}) do
    local props = {}
    for _, p in ipairs(test.properties or {}) do
      props[p.name] = p.value
    end
    local cwd = props.WORKING_DIRECTORY or build
    for _, arg in ipairs(test.command or {}) do
      local path = discovery.join(cwd, arg)
      covered[vim.uv.fs_realpath(path) or path] = true
    end
    local env = {}
    for _, entry in ipairs(props.ENVIRONMENT or {}) do
      local k, v = entry:match('^([^=]+)=(.*)$')
      if k then
        env[k] = v
      end
    end
    if
      selected(test.command and test.command[1], cwd)
      and discovery.framework(test.command, opts.frameworks, cwd) == 'gtest'
    then
      local command = vim.deepcopy(test.command)
      -- Keep the registration's existing filter and arguments when enumerating.
      command[#command + 1] = '--gtest_list_tests'
      out[#out + 1] = {
        kind = 'ctest',
        name = test.name,
        keys = listed(ctx, command, cwd, env),
        executable = discovery.join(cwd, test.command[1]),
        command = test.command,
        cwd = cwd,
        env = env,
        properties = props,
      }
    end
  end
  -- The same File API fallback as cmake-tests.nvim: executable targets need
  -- not have add_test()/gtest_discover_tests() registrations.
  for _, exe in ipairs(selection.artifacts) do
    local path = vim.uv.fs_realpath(exe) or exe
    if
      selected(exe, build)
      and not covered[path]
      and discovery.framework({ exe }, opts.frameworks, build) == 'gtest'
    then
      covered[path] = true
      out[#out + 1] = {
        kind = 'direct',
        name = exe,
        executable = exe,
        command = { exe },
        cwd = build,
        env = {},
        properties = {},
        keys = listed(ctx, { exe, '--gtest_list_tests' }, build, {}),
      }
    end
  end
  return out
end

function M.keys(path)
  local ctx = M.context(path)
  local build, opts = ctx.build_dir, ctx.options
  local cached = ctx.state.keys[path]
  local keys = cached and cached.keys or {}
  local selection = select(ctx, { [path] = true })
  local fresh, stamp = #selection.targets > 0 and not ctx.state.unbuilt[path], {}
  for _, target in ipairs(selection.targets) do
    for _, exe in ipairs(target.executables) do
      local binary = vim.uv.fs_stat(exe)
      stamp[#stamp + 1] = binary and binary.mtime or false
      for source in pairs(target.files) do
        local input = vim.uv.fs_stat(source)
        if
          not binary
          or not input
          or input.mtime.sec > binary.mtime.sec
          or (input.mtime.sec == binary.mtime.sec and input.mtime.nsec > binary.mtime.nsec)
        then
          fresh = false
        end
      end
    end
  end
  stamp = vim.json.encode(stamp)
  -- Editing/saving a file must not launch its old binary just to rediscover
  -- parameter names. Keep known names until a successful build changes it.
  if (opts.build == false or fresh) and (not cached or cached.model ~= selection.model or cached.stamp ~= stamp) then
    keys = {}
    if vim.uv.fs_stat(build .. '/CMakeCache.txt') then
      for _, entry in ipairs(M.registrations(selection)) do
        vim.list_extend(keys, entry.keys)
      end
    end
    ctx.state.keys[path] = { model = selection.model, stamp = stamp, keys = keys }
  end
  return keys
end

local function discover(given)
  require('nio').scheduler()
  local root = vim.uv.fs_realpath(given.root) or vim.fs.normalize(given.root)
  local ctx = context(root, given.build_dir, given.config or configured_options.config)
  local selection = select(ctx)
  assert(#selection.artifacts > 0, 'neotest-cmake: no executable targets in CMake File API reply at ' .. ctx.build_dir)
  local binaries, count = {}, 0
  for _, entry in ipairs(M.registrations(selection)) do
    for _, case in ipairs(entry.keys) do
      local binary = entry.executable
      binaries[binary] = binaries[binary] or {}
      if not binaries[binary][case.key] then
        binaries[binary][case.key] = true
        count = count + 1
      end
    end
  end
  ctx.state.unbuilt = {}
  builds[root] = { build_dir = ctx.build_dir, config = ctx.config }
  return {
    root = root,
    build_dir = ctx.build_dir,
    config = ctx.config,
    binaries = vim.tbl_count(binaries),
    cases = count,
  }
end

---@param given neotest-cmake.DiscoveryContext
---@return neotest-cmake.DiscoveryResult
function M.discover(given)
  local root = vim.uv.fs_realpath(given.root) or vim.fs.normalize(given.root)
  return require('neotest-cmake.activity').with(root, function()
    return discover(given)
  end)
end

local function file_stamp(path)
  local stat = vim.uv.fs_stat(path)
  return stat and { stat.size, stat.mtime.sec, stat.mtime.nsec } or false
end

local function snapshot(selection, artifacts)
  local ctx = selection.context
  local paths = vim.tbl_extend('force', selection.affected, {
    [ctx.build_dir .. '/CMakeCache.txt'] = true,
    [ctx.root .. '/CMakePresets.json'] = true,
    [ctx.root .. '/CMakeUserPresets.json'] = true,
    [ctx.root .. '/CMakeLists.txt'] = true,
  })
  for _, target in ipairs(selection.model) do
    for _, path in ipairs((target.backtraceGraph or {}).files or {}) do
      paths[discovery.join(ctx.root, path)] = true
    end
  end
  if artifacts then
    for _, exe in ipairs(selection.artifacts) do
      paths[exe] = true
    end
  end
  local stamp = {}
  for path in pairs(paths) do
    stamp[path] = file_stamp(path)
  end
  return stamp
end

function M.prepare(tree, parent)
  local ctx = M.context(tree:data().path)
  local selection = select(ctx, M.files(tree))
  local failure
  if ctx.options.build == false then
    selection.stamp = snapshot(selection)
    return selection
  end
  ctx.lock.with(function()
    local function mark(pending)
      for path in pairs(selection.affected) do
        ctx.state.unbuilt[path] = pending or nil
      end
    end
    local function fail(stage, result)
      failure = diagnostics.report(ctx.root, ctx.build_dir, stage, result)
      failure.files = selection.affected
    end
    mark(true)
    if not vim.uv.fs_stat(ctx.build_dir .. '/CMakeCache.txt') then
      fail('configure', { code = 1, stderr = 'Configure the CMake build first: ' .. ctx.build_dir })
      return
    end
    if #selection.model == 0 then
      local query = ctx.build_dir .. '/.cmake/api/v1/query'
      vim.fn.mkdir(query, 'p')
      vim.fn.writefile({}, query .. '/codemodel-v2')
      local command = { ctx.options.cmake, '-S', ctx.root, '-B', ctx.build_dir }
      local result = parent
          and require('neotest-cmake.overseer').process(parent, command, ctx.root, ctx.options.build_timeout)
        or process(ctx, command, ctx.root, nil, ctx.options.build_timeout)
      if result.code ~= 0 then
        fail('configure', result)
        return
      end
    end
    -- Configuration (or another queued build) may have changed ownership.
    if selection.model ~= discovery.targets(ctx.build_dir, ctx.config) then
      selection = select(ctx, selection.files)
      mark(true)
    end
    if #selection.targets == 0 then
      fail(
        'configure',
        { code = 1, stderr = 'No executable target owns the selected test sources in ' .. ctx.build_dir }
      )
      return
    end
    local command = { ctx.options.cmake, '--build', ctx.build_dir }
    if ctx.config ~= '' then
      vim.list_extend(command, { '--config', ctx.config })
    end
    command[#command + 1] = '--target'
    for _, target in ipairs(selection.targets) do
      command[#command + 1] = target.name
    end
    selection.stamp = snapshot(selection)
    local result = parent
        and require('neotest-cmake.overseer').process(parent, command, ctx.root, ctx.options.build_timeout)
      or process(ctx, command, ctx.root, nil, ctx.options.build_timeout)
    if result.code ~= 0 then
      fail('build', result)
      return
    end
    mark(false)
    diagnostics.clear(ctx.root, ctx.build_dir)
  end)
  return selection, failure
end

---@param selection neotest-cmake.Selection
---@return neotest-cmake.Prepared
function M.prepared(selection)
  -- Source/configuration stamps come from before the build. Capture only the
  -- output artifacts afterwards, so edits during preparation cannot be blessed.
  local stamp = vim.tbl_extend('force', selection.stamp, {})
  for _, exe in ipairs(selection.artifacts) do
    stamp[exe] = file_stamp(exe)
  end
  return { selection = selection, stamp = stamp }
end

function M.reuse(prepared, tree)
  if type(prepared) ~= 'table' or not prepared.selection or prepared.used then
    return
  end
  prepared.used = true
  local selection, ctx = prepared.selection, M.context(tree:data().path)
  local previous = selection.context
  if
    ctx.root == previous.root
    and ctx.build_dir == previous.build_dir
    and ctx.config == previous.config
    and ctx.options == previous.options
    and selection.model == discovery.targets(ctx.build_dir, ctx.config)
    and vim.deep_equal(selection.files, M.files(tree))
    and vim.deep_equal(prepared.stamp, snapshot(selection, true))
  then
    return selection
  end
end
return M
