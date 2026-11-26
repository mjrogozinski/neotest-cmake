local path = vim.fn.tempname() .. '.cpp'
local text = [=[
// TEST(Comment, Ignored) {}
const char* fake = "TEST(String, Ignored) {}";
void ordinary() { TEST(Call, Ignored); }
OTHER(Unrelated, Ignored) {}
TEST(TooFew) {}
TEST(Too, Many, Arguments) {}
namespace nested {
TEST(Basic, Pass) { if (true) { ordinary(); } }
TEST_F(Fixture, Pass) {}
TEST_P(Values, Pass) {}
TYPED_TEST(Types, Pass) {}
TYPED_TEST_P(TypeParameters, Pass) {}
TEST(
  Multiline,
  Pass
) {}
}
]=]
vim.fn.writefile(vim.split(text, '\n'), path)
require('nio').run(function()
  local ok, err = xpcall(function()
    local file, definitions = require('neotest-cmake.source').definitions(path)
    assert(file.path == path and file.type == 'file')
    local expected = {
      { 'TEST', 'Basic.Pass' },
      { 'TEST_F', 'Fixture.Pass' },
      { 'TEST_P', 'Values.Pass' },
      { 'TYPED_TEST', 'Types.Pass' },
      { 'TYPED_TEST_P', 'TypeParameters.Pass' },
      { 'TEST', 'Multiline.Pass' },
    }
    assert(#definitions == #expected, vim.inspect(definitions))
    for i, want in ipairs(expected) do
      local pos = definitions[i]
      assert(pos.kind == want[1] and pos.name == want[2], vim.inspect(pos))
      assert(pos.id == path .. '::' .. want[2] and pos.path == path and pos.type == 'test')
      local lines = vim.split(text, '\n')
      assert(lines[pos.range[1] + 1]:find(want[1], 1, true), 'incorrect start range')
      assert(lines[pos.range[3] + 1]:sub(pos.range[4], pos.range[4]) == '}', 'incorrect end range')
    end
  end, debug.traceback)
  os.remove(path)
  if not ok then
    io.stderr:write(err .. '\n')
    vim.cmd('cquit 1')
  end
  io.stdout:write('Source query tests passed\n')
  vim.cmd('qa!')
end)
