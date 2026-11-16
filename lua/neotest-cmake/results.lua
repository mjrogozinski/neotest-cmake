local discovery = require('neotest-cmake.discovery')
local parsers = require('neotest-cmake.parsers')
local M = {}
local rank = { skipped = 1, passed = 2, failed = 3 }

function M.worst(a, b)
  if not rank[b] then return a end
  if not rank[a] or rank[b] > rank[a] then return b end
  return a
end

function M.merge(out, id, value)
  if not out[id] or M.worst(out[id].status, value.status) ~= out[id].status then out[id] = value end
end

function M.collect(spec, result)
  if spec.context.build_failure then
    local out = {}
    for _, id in ipairs(spec.context.tests) do
      out[id] = { status = 'skipped', output = spec.context.build_failure.output,
        short = spec.context.build_failure.summary .. '; see quickfix',
        build_failure = spec.context.build_failure }
    end
    return out
  end
  if spec.context.runs then
    local out = {}
    for _, run in ipairs(spec.context.runs) do
      local collected = M.collect(run, { code = result.code, output = run.context.output })
      for id, value in pairs(collected) do
        value.output = result.output
        -- A source definition can be compiled into more than one binary.
        M.merge(out, id, value)
      end
      os.remove(run.context.output)
    end
    os.remove(spec.context.manifest)
    return out
  end
  local xml = spec.context.report and discovery.read(spec.context.report)
  local out, seen = {}, {}
  local function add(id, status, message)
    M.merge(out, id, { status = status, output = result.output, short = message })
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

return M
