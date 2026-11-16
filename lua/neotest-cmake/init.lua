local discovery = require('neotest-cmake.discovery')
local source = require('neotest-cmake.source')
local project = require('neotest-cmake.project')
local diagnostics = require('neotest-cmake.diagnostics')
local activity = require('neotest-cmake.activity')
local M = { name = 'neotest-cmake' }
local runner = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/runner.lua'
M.root, M.discover = project.root, project.discover
function M.filter_dir(name, relpath, root)
  return name ~= '.git' and name ~= 'CMakeFiles'
    and discovery.join(root, relpath) ~= project.context(root).build_dir
end
function M.is_test_file(path)
  if not vim.tbl_contains({ 'c', 'cc', 'cpp', 'cxx', 'h', 'hpp', 'hxx' }, vim.fn.fnamemodify(path, ':e')) then return false end
  return activity.with(project.root(path), function()
    local _, definitions = source.definitions(path)
    return #definitions > 0
  end)
end
function M.discover_positions(path)
  return activity.with(project.root(path), function()
    local file, definitions = source.definitions(path)
    if #definitions == 0 then return nil end
    return source.tree(file, definitions, project.keys(path))
  end)
end
function M.prepare(tree)
  local selection, failure = project.prepare(tree)
  local ctx = selection.context
  return not failure and selection.files or nil, ctx.build_dir, ctx.config, failure,
    not failure and project.prepared(selection) or nil
end

local function regex(s) return (s:gsub('([\\%.%[%]%^%$%*%+%?%(%){|}])', '\\%1')) end

function M.build_spec(args)
  local selection = project.reuse(args._cmake_prepared, args.tree)
  local failure
  if not selection then selection, failure = project.prepare(args.tree) end
  if failure then return diagnostics.blocked(args.tree, failure) end
  local ctx = selection.context
  local build, config, opts = ctx.build_dir, ctx.config, ctx.options
  local tests = {}
  for _, node in args.tree:iter_nodes() do
    local pos = node:data()
    if pos.type == 'test' then tests[#tests + 1] = pos end
  end
  assert(#tests > 0, 'neotest-cmake: no GoogleTest source positions selected')
  local selected, mappings, specs, matched, debugging = {}, {}, {}, {}, {}
  for _, reg in ipairs(project.registrations(selection)) do
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
    .. '; check source ownership and compiled GoogleTest definitions.')
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
  project.configure(config)
  return M
end })
