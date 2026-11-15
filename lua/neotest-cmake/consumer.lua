local nio = require('nio')

-- Refresh the source tree after building, before Neotest selects concrete cases.
-- Plain neotest/summary runs also build through the adapter's build_spec.
return function(client)
  local M = {}
  client.listeners.results = function(adapter_id, results, partial)
    if partial or not vim.startswith(adapter_id, 'neotest-cmake:') then return end
    local groups = {}
    for id in pairs(results) do
      local node = client:get_position(id, { adapter = adapter_id })
      if node and node:data().key then
        for parent in node:iter_parents() do
          if parent:data().type == 'namespace' then groups[parent:data().id] = parent end
        end
      end
    end
    -- Neotest only aggregates parents inside the selected subtree. Recompute
    -- the definition after individual-instance runs using all known siblings.
    local known, updates = client:get_results(adapter_id), {}
    local rank = { skipped = 1, passed = 2, failed = 3 }
    for id, group in pairs(groups) do
      local status
      for _, child in ipairs(group:children()) do
        local result = known[child:data().id]
        if result and rank[result.status] and (not status or rank[result.status] > rank[status]) then
          status = result.status
        end
      end
      if status and (not known[id] or known[id].status ~= status) then
        updates[id] = vim.tbl_extend('force', known[id] or {}, { status = status })
      end
    end
    if next(updates) then client._state:update_results(adapter_id, updates, true) end
  end
  M.run = nio.create(function(args)
    args = type(args) == 'string' and { args } or args or {}
    local neotest = require('neotest')
    local stat = args[1] and vim.uv.fs_stat(args[1])
    if stat and stat.type == 'directory' then
      client:_update_positions(args[1], { adapter = args.adapter })
    end
    local tree = neotest.run.get_tree_from_args(args)
    if not tree then return neotest.run.run(args) end
    local _, adapter_id = client:get_position(tree:data().id, args)
    if vim.startswith(adapter_id or '', 'neotest-cmake:') then
      local files = require('neotest-cmake').prepare(tree)
      if not files then return end
      for path in pairs(files) do client:_update_positions(path, { adapter = adapter_id }) end
    end
    neotest.run.run(args)
  end, 1)
  M.refresh = nio.create(function(path)
    local root = require('neotest-cmake').root(path)
    client:_update_positions(path, { adapter = root and 'neotest-cmake:' .. root })
  end, 1)
  return M
end
