local M = {}
function M.gtest_list(text)
  local result, suite = {}, nil
  for line in text:gmatch('[^\r\n]+') do
    line = line:gsub('%s+#.*$', '')
    if line:match('^%S.*%.$') then
      suite = line:sub(1, -2)
    elseif suite and line:match('^%s+%S') then
      local name = vim.trim(line)
      result[#result + 1] = { suite = suite, name = name, key = suite .. '.' .. name,
        disabled = suite:match('^DISABLED_') ~= nil or suite:find('/DISABLED_', 1, true) ~= nil
          or name:match('^DISABLED_') ~= nil }
    end
  end
  return result
end
function M.results(text)
  local results, current, log = {}, nil, {}
  for line in text:gmatch('[^\r\n]+') do
    line = line:gsub('\27%[[%d;]*m', '')
    local start = line:match('^%[ RUN      %] (.+)$')
    if start then current, log = start, {} end
    if current then log[#log + 1] = line end
    local status, key = line:match('^%[%s*(OK)%s*%] (.-) %(')
    if not key then status, key = line:match('^%[%s*(FAILED)%s*%] (.-) %(') end
    if not key then status, key = line:match('^%[%s*(SKIPPED)%s*%] (.-) %(') end
    if key and current == key then
      results[#results + 1] = { key = key, status = ({ OK = 'passed', FAILED = 'failed', SKIPPED = 'skipped' })[status],
        output = table.concat(log, '\n') }
      current = nil
    end

  end
  if current then results[#results + 1] = { key = current, status = 'failed', output = table.concat(log, '\n') } end
  return results
end
local function decode(s)
  s = s:gsub('<!%[CDATA%[(.-)%]%]>', '%1')
  return (s:gsub('&#x(%x+);', function(n) return vim.fn.nr2char(tonumber(n, 16)) end)
    :gsub('&#(%d+);', function(n) return vim.fn.nr2char(tonumber(n)) end)
    :gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&quot;', '"'):gsub('&apos;', "'"):gsub('&amp;', '&'))
end
function M.junit(xml)
  local out = {}
  for attrs, body in xml:gmatch('<testcase%s+([^>]-)>(.-)</testcase>') do
    local name = attrs:match('name="(.-)"')
    if name then
      local output = body:match('<system%-out[^>]*>(.-)</system%-out>') or ''
      out[#out + 1] = { name = decode(name), output = decode(output),
        status = body:find('<failure[%s/>]') and 'failed'
          or body:find('<error[%s/>]') and 'failed'
          or (body:find('<skipped[%s/>]') or attrs:find('status="disabled"', 1, true) or attrs:find('status="notrun"', 1, true)) and 'skipped' or 'passed',
        duration = tonumber(attrs:match('time="(.-)"')) }
    end
  end
  return out
end
return M
