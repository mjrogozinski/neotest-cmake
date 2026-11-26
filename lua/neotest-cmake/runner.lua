-- Standalone Neovim Lua entrypoint: no user configuration or plugins loaded.
-- Keep argv arrays intact; paths/filters never pass through shell expansion.
local file = assert(io.open(arg[1], 'rb'))
local commands = vim.json.decode(file:read('*a'))
file:close()
local current, cancelled, exit_code = nil, false, 0
local signals = {}
for _, name in ipairs({ 'sigterm', 'sigint' }) do
  local signal = vim.uv.new_signal()
  signal:start(name, function()
    cancelled = true
    if current then
      current:kill(15)
    end
  end)
  signals[#signals + 1] = signal
end
for _, spec in ipairs(commands) do
  if cancelled then
    exit_code = 1
    break
  end
  local chunks = {}
  local function output(_, data)
    if data then
      chunks[#chunks + 1] = data
      io.stdout:write(data)
      io.stdout:flush()
    end
  end
  local ok, result = pcall(function()
    current = vim.system(spec.command, { cwd = spec.cwd, text = true, stdout = output, stderr = output })
    return current:wait()
  end)
  current = nil
  if not ok then
    chunks[#chunks + 1] = tostring(result)
  end
  local captured = assert(io.open(spec.output, 'wb'))
  captured:write(table.concat(chunks))
  captured:close()
  if not ok or result.code ~= 0 or cancelled then
    exit_code = 1
  end
end
for _, signal in ipairs(signals) do
  signal:stop()
  signal:close()
end
os.exit(exit_code)
