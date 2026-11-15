local M = {}
function M.write(path, text)
  -- macOS ships Make 3.81, which compares timestamps at second resolution.
  -- Ensure an edit is newer than the artifacts from the preceding build.
  local now = os.time()
  repeat require('nio').sleep(20) until os.time() > now
  local file = assert(io.open(path, 'w'))
  file:write(text)
  file:close()
end
return M
