local nio = require('nio')
local activity = require('neotest-cmake.activity')
local results = require('neotest-cmake.results')

-- Refresh the source tree after building, before Neotest selects concrete cases.
-- Plain neotest/summary runs also build through the adapter's build_spec.
return function(client)
  local M = {}
  local starting = {}
  client.listeners.starting = function()
    local paths = { vim.uv.cwd() }
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local path = vim.api.nvim_buf_get_name(buf)
      if path ~= '' then
        paths[#paths + 1] = path
      end
    end
    for _, path in ipairs(paths) do
      local root = require('neotest-cmake').root(path)
      if root and not starting[root] then
        starting[root] = activity.start(root)
      end
    end
  end
  client.listeners.started = function()
    for _, finish in pairs(starting) do
      finish()
    end
    starting = {}
  end
  -- Guard the public run entry points before Neotest tries to resolve an
  -- incomplete tree (and emits its generic "No tests found" notification).
  local run = require('neotest.consumers.run')(client)
  if not run._cmake_discovery_guard then
    for _, name in ipairs({ 'run', 'run_last' }) do
      local original = run[name]
      run[name] = nio.create(function(args)
        local selected = args
        if name == 'run_last' then
          local position, previous = run.get_last_run()
          if position then
            selected = vim.tbl_extend('force', previous or {}, args or {}, { position })
          end
        end
        if activity.blocked(selected) then
          return
        end
        -- Startup itself can yield before a tree exists. Check again after
        -- initialization so an overlapping scan never reaches tree selection.
        client:get_adapters()
        if activity.blocked(selected) then
          return
        end
        return original(args)
      end, 1)
    end
    run._cmake_discovery_guard = true
  end
  local function invalidate(adapter_id, files)
    local root = client:get_position(nil, { adapter = adapter_id })
    local known = client:get_results(adapter_id)
    for path in pairs(files) do
      local tree = root and root:get_key(path)
      if tree then
        for _, pos in tree:iter() do
          known[pos.id] = nil
          client._state:running(adapter_id)[pos.id] = nil
        end
        for parent in tree:iter_parents() do
          known[parent:data().id] = nil
        end
        -- Reuse position notifications to redraw neutral (not-run) signs and
        -- summary rows without manufacturing a test run or an unknown status.
        client._state:update_positions(adapter_id, tree)
      end
    end
  end
  -- Preparation is part of the run: clear old results and render Neotest's
  -- running icon before the first asynchronous configure/build operation.
  local function preparing(tree, adapter_id, action)
    local ids, files = {}, {}
    for _, pos in tree:iter() do
      ids[#ids + 1] = pos.id
      if pos.type == 'file' or pos.type == 'test' or pos.type == 'namespace' then
        files[pos.path] = true
      end
    end
    client._state:update_running(adapter_id, tree:data().id, ids)
    local ok, result = xpcall(action, debug.traceback)
    -- Normal execution has already cleared these flags via final results.
    -- Failed/cancelled preparation and exceptions must clear them as well.
    local running = client._state:running(adapter_id)
    for _, id in ipairs(ids) do
      running[id] = nil
    end
    for path in pairs(files) do
      local file = client:get_position(path, { adapter = adapter_id })
      if file then
        client._state:update_positions(adapter_id, file)
      end
    end
    if not ok then
      error(result, 0)
    end
    return result
  end
  client.listeners.results = function(adapter_id, updates, partial)
    if not vim.startswith(adapter_id, 'neotest-cmake:') then
      return
    end
    for _, result in pairs(updates) do
      if result.build_failure then
        invalidate(adapter_id, result.build_failure.files)
        return
      end
    end
    if partial then
      return
    end
    local groups = {}
    for id in pairs(updates) do
      local node = client:get_position(id, { adapter = adapter_id })
      if node and node:data().key then
        for parent in node:iter_parents() do
          if parent:data().type == 'namespace' then
            groups[parent:data().id] = parent
          end
        end
      end
    end
    -- Neotest only aggregates parents inside the selected subtree. Recompute
    -- the definition after individual-instance runs using all known siblings.
    local known, aggregated = client:get_results(adapter_id), {}
    for id, group in pairs(groups) do
      local status
      for _, child in ipairs(group:children()) do
        local result = known[child:data().id]
        if result then
          status = results.worst(status, result.status)
        end
      end
      if status and (not known[id] or known[id].status ~= status) then
        aggregated[id] = vim.tbl_extend('force', known[id] or {}, { status = status })
      end
    end
    if next(aggregated) then
      client._state:update_results(adapter_id, aggregated, true)
    end
  end
  M.run = nio.create(function(args)
    args = type(args) == 'string' and { args } or args or {}
    activity.wait(args)
    local neotest = require('neotest')
    local stat = args[1] and vim.uv.fs_stat(args[1])
    if stat and stat.type == 'directory' then
      client:_update_positions(args[1], { adapter = args.adapter })
    end
    local tree = neotest.run.get_tree_from_args(args)
    activity.wait(args)
    if not tree then
      return neotest.run.run(args)
    end
    local _, adapter_id = client:get_position(tree:data().id, args)
    if not vim.startswith(adapter_id or '', 'neotest-cmake:') or args.strategy == 'dap' then
      if args.strategy == 'dap' and vim.startswith(adapter_id or '', 'neotest-cmake:') then
        return preparing(tree, adapter_id, function()
          local files, _, _, failure, prepared = require('neotest-cmake').prepare(tree)
          if not files then
            invalidate(adapter_id, failure.files)
            return
          end
          for path in pairs(files) do
            client:_update_positions(path, { adapter = adapter_id })
          end
          args = vim.tbl_extend('force', args, { _cmake_prepared = prepared })
          return neotest.run.run(args)
        end)
      end
      return neotest.run.run(args)
    end
    local integration = require('neotest-cmake.overseer')
    local function execute(parent)
      return preparing(tree, adapter_id, function()
        local files, _, _, failure, prepared = require('neotest-cmake').prepare(tree, parent)
        if not files then
          invalidate(adapter_id, failure.files)
          return false
        end
        if parent and not parent:is_running() then
          return false
        end
        for path in pairs(files) do
          client:_update_positions(path, { adapter = adapter_id })
        end
        args = vim.tbl_extend('force', args, { _cmake_prepared = prepared, _cmake_parent = parent })
        if parent then
          args.strategy = 'overseer'
          tree = neotest.run.get_tree_from_args(args, true)
          if not tree then
            return false
          end
          if neotest.overseer then
            neotest.overseer.run(args)
          else
            client:run_tree(tree, args)
          end
        else
          neotest.run.run(args)
        end
        return true
      end)
    end
    if not integration.parent(tree:root():data().path, tree:data().name, execute) then
      execute(nil)
    end
  end, 1)
  M.refresh = nio.create(function(path)
    local root = require('neotest-cmake').root(path)
    if not root then
      return
    end
    activity.with(root, function()
      client:_update_positions(path, { adapter = 'neotest-cmake:' .. root })
    end)
  end, 1)
  return M
end
