# neotest-cmake

[![Tests](https://github.com/mjrogozinski/neotest-cmake/actions/workflows/test.yml/badge.svg)](https://github.com/mjrogozinski/neotest-cmake/actions/workflows/test.yml)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Build, discover, run, and debug GoogleTest tests from Neovim.**

A [Neotest](https://github.com/nvim-neotest/neotest) adapter that connects C++ source positions to your actual CMake targets. It uses Tree-sitter for source discovery, the CMake File API for target ownership, and CTest for registered test execution.

- **Build before running.** Build the selected executable and its dependencies; never run its old tests after a failed build.
- **Every parameter gets a row.** Run individual value and type instances, or the whole source definition.
- **Keep CTest behavior.** Preserve fixtures, working directories, environment variables, timeouts, and skip/expected-failure rules in normal registered runs.
- **No test registration required.** Discover unregistered GoogleTest executables through the File API and run them directly.
- **Useful failures.** Open compiler errors in quickfix and reset stale results to neutral not-run marks through the CMake consumer.
- **Use your toolchain.** Select an existing build directory, including preset and out-of-tree builds.

[Requirements](#requirements) · [Installation](#installation) · [Project setup](#project-setup) · [Usage](#usage) · [Configuration](#configuration) · [Debugging](#debugging) · [Troubleshooting](#troubleshooting-and-limitations)

## Requirements

| Requirement | Details |
| --- | --- |
| Neovim | **0.10+** for the adapter APIs. CI runs Neovim 0.11.5. Your dependency versions may require a newer Neovim. |
| CMake and CTest | **3.21+**, available to Neovim through `PATH`, or configured with `cmake` and `ctest`. |
| Project toolchain | A working C++ compiler and the generator's build tool, such as Make or Ninja. Launch Neovim in the environment needed to build your project. |
| GoogleTest | Supplied and linked by your CMake project. The adapter does not install it. |
| Lua plugins | [neotest](https://github.com/nvim-neotest/neotest), [nvim-nio](https://github.com/nvim-neotest/nvim-nio), and [plenary.nvim](https://github.com/nvim-lua/plenary.nvim). |
| Tree-sitter | An installed **`cpp` parser**, visible on Neovim's runtime path. Syntax highlighting does not have to be enabled. |
| Paths | The current resolver expects Unix-style absolute paths. Native Windows paths are not supported. |
| Optional debugging | [nvim-dap](https://github.com/mfussenegger/nvim-dap) and a configured debugger adapter; `codelldb` is the default adapter type. |

No starter configuration, LSP server, Overseer integration, or particular plugin manager is required. A Nerd Font is optional for Neotest's default icons.

## Installation

Choose **one** method. These examples configure the adapter and its CMake consumer, which refreshes parameter discovery before a run and clears stale results after build failures.

### lazy.nvim

Add this specification to the plugin list you pass to [lazy.nvim](https://lazy.folke.io/spec):

```lua
{
  "nvim-neotest/neotest",
  dependencies = {
    "nvim-neotest/nvim-nio",
    "nvim-lua/plenary.nvim",
    "mjrogozinski/neotest-cmake",
  },
  config = function()
    require("neotest").setup({
      consumers = {
        cmake = require("neotest-cmake.consumer"),
      },
      adapters = {
        require("neotest-cmake")({ build_dir = "build" }),
      },
    })
  end,
}
```

If you keep specifications in separate Lua files, return that table from the file. If Neotest is already configured, add the dependency, consumer, and adapter to your existing setup instead of calling `setup()` a second time.

### Native package manager (Neovim 0.12+)

With Neovim's built-in [`vim.pack`](https://neovim.io/doc/user/pack/#vim.pack), add this to `init.lua`:

```lua
vim.pack.add({
  { src = "https://github.com/nvim-neotest/nvim-nio" },
  { src = "https://github.com/nvim-lua/plenary.nvim" },
  { src = "https://github.com/nvim-neotest/neotest" },
  { src = "https://github.com/mjrogozinski/neotest-cmake" },
})

require("neotest").setup({
  consumers = { cmake = require("neotest-cmake.consumer") },
  adapters = { require("neotest-cmake")({ build_dir = "build" }) },
})
```

### Native packages (Neovim 0.10 or 0.11)

Neovim also loads plugins from native [`pack/*/start` directories](https://neovim.io/doc/user/pack/#packages). On Linux and macOS, these commands install into the default data directory:

```sh
mkdir -p ~/.local/share/nvim/site/pack/plugins/start
cd ~/.local/share/nvim/site/pack/plugins/start

git clone https://github.com/nvim-neotest/nvim-nio.git
git clone https://github.com/nvim-lua/plenary.nvim.git
git clone https://github.com/nvim-neotest/neotest.git
git clone https://github.com/mjrogozinski/neotest-cmake.git
```

If you use `XDG_DATA_HOME` or `NVIM_APPNAME`, find your data directory with `:lua print(vim.fn.stdpath("data"))` and use its `site/pack/plugins/start` directory instead. Restart Neovim, then add the `require("neotest").setup(...)` block from the native package manager example to `init.lua`.

### Install the C++ parser

Plugin installation does **not** install the parser. You can use [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter), or any other method that installs a compatible `cpp` parser on your runtime path.

With a compatible version of nvim-treesitter installed, run:

```vim
:TSInstall cpp
```

Follow nvim-treesitter's own installation and version requirements; its current branch may require a newer Neovim than this adapter. To verify that the parser is available:

```vim
:lua print(pcall(vim.treesitter.get_string_parser, "int main() {}", "cpp"))
```

The first printed value should be `true`.

## Project setup

### Expected project structure

**No particular source directory, test filename, target name, or executable location is required.** In particular, tests do not have to live in `tests/` or end in `_test.cpp`.

The adapter does assume:

1. **A CMake project root.** It searches upward for `CMakePresets.json` or `.git`, falling back to `CMakeLists.txt`. Set `root` explicitly for a nested project or monorepo where those markers identify the wrong directory.
2. **A configured build tree.** `build_dir` defaults to `build`, relative to the project root. Set it for any other layout; absolute paths outside the source tree are supported. The adapter does not choose a preset for you.
3. **File API target metadata.** The build tree must provide a `codemodel-v2` reply. The commands below request it. For an already configured build without a reply, the adapter requests the metadata and reconfigures using that build's existing cache.
4. **Explicit source ownership.** Test source files must appear in the File API's target sources, either directly in an executable or in a linked library. For tests defined in headers, list those headers in the consuming executable's `target_sources()` so CMake records their ownership. Headers supplied only through interface libraries may be absent from the File API codemodel; see the [real-project trials](docs/real-project-trials.md).
5. **GoogleTest source definitions.** Discovery recognizes `TEST`, `TEST_F`, `TEST_P`, `TYPED_TEST`, and `TYPED_TEST_P`. It scans `.c`, `.cc`, `.cpp`, `.cxx`, `.h`, `.hpp`, and `.hxx` files with the C++ parser.

For example, this layout works, but the names are only illustrative:

```text
project/
├── CMakeLists.txt
├── source/
│   └── checks.cpp
└── out/
    └── debug/          # configure build_dir = "out/debug"
```

### Minimal CMake project

This example expects GoogleTest to be installed and discoverable by CMake. You can instead supply it through your project's existing dependency setup.

```cmake
cmake_minimum_required(VERSION 3.21)
project(example LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(CTest)
if(BUILD_TESTING)
    find_package(GTest CONFIG REQUIRED)
    add_executable(unit_tests source/checks.cpp)
    target_link_libraries(unit_tests PRIVATE GTest::gtest_main)

    include(GoogleTest)
    gtest_discover_tests(unit_tests)
endif()
```

```cpp
// source/checks.cpp
#include <gtest/gtest.h>

TEST(Arithmetic, Adds)
{
    EXPECT_EQ(2 + 2, 4);
}
```

`gtest_discover_tests()` gives precise CTest selection. You may also use `add_test()` to register an executable or group of cases. Registration is optional: executable targets with no CTest registration are discovered through the File API and run directly with a GoogleTest filter.

### Configure the build

From the project root:

```sh
mkdir -p build/.cmake/api/v1/query
touch build/.cmake/api/v1/query/codemodel-v2
cmake -S . -B build -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build --parallel
```

The initial build makes concrete parameter instances available for discovery. Subsequent test runs build the relevant targets automatically.

Use your normal compiler, toolchain file, or configure preset for the initial configuration. If dependencies require environment variables, compiler wrappers, or a development shell, Neovim needs that same environment. A compilation database or symlink is **not** required by the adapter.

## Usage

Save your changes, open a test source file, and run:

```lua
require("neotest").cmake.run()                  -- nearest definition: build, refresh, run
require("neotest").cmake.run(vim.fn.expand("%:p")) -- current file
require("neotest").summary.toggle()            -- test tree and individual parameter rows
require("neotest").output.open({ enter = true }) -- output for the selected test
```

The plugin does not install keymaps. The `cmake.run()` consumer builds first, refreshes source positions, then invokes Neotest. Standard `neotest.run.run()` and summary actions also build through the adapter; the consumer additionally handles discovery refresh and stale-result invalidation.

Build errors open **quickfix** with clickable file and line locations. Tests in the affected binary return to neutral not-run marks, including tests in sibling source files; unrelated binaries keep their results. Discovery reuses known parameter names while sources are unbuilt, without launching the old binary. A successful rebuild clears the adapter's current quickfix list. With Trouble installed, use `:Trouble qflist open` to view the same list.

### Suggested keymaps

Add these after your Neotest setup, or inside the lazy.nvim `config` function:

```lua
local function run(args)
  vim.cmd("wall") -- stop here if modified buffers cannot be saved
  require("neotest").cmake.run(args)
end

vim.keymap.set("n", "<leader>tn", function() run() end,
  { desc = "Test nearest" })
vim.keymap.set("n", "<leader>tf", function() run(vim.fn.expand("%:p")) end,
  { desc = "Test file" })
vim.keymap.set("n", "<leader>ta", function()
  local root = require("neotest-cmake").root(vim.api.nvim_buf_get_name(0))
  if root then run({ root, adapter = "neotest-cmake:" .. root }) end
end, { desc = "Test CMake project" })
vim.keymap.set("n", "<leader>ts", function() require("neotest").summary.toggle() end,
  { desc = "Test summary" })
vim.keymap.set("n", "<leader>to", function() require("neotest").output.open({ enter = true }) end,
  { desc = "Test output" })
vim.keymap.set("n", "<leader>tx", function() require("neotest").run.stop() end,
  { desc = "Stop test run" })
```

### Parameterized tests

Each concrete instance keeps its GoogleTest name, rather than CTest's potentially prettified display name:

```text
Values.Positive
├── Numbers/Values.Positive/0
├── Numbers/Values.Positive/1
└── Named/Values.Positive/Three
Typed.Size
├── Typed/0.Size
└── Typed/1.Size
TypeParameters.Size
├── Instances/TypeParameters/0.Size
└── Instances/TypeParameters/1.Size
```

Running nearest from a source definition selects the whole group. Selecting a child in the Neotest summary runs that instance. A source definition has one aggregate status mark: **any failing parameter makes the definition fail**, while each summary child retains its own result.

## Configuration

All adapter options and their defaults:

```lua
require("neotest-cmake")({
  build_dir = "build",       -- relative to root, absolute, or function(root) -> path
  config = "",               -- e.g. "Debug" for a multi-config generator
  cmake = "cmake",
  ctest = "ctest",
  build = true,              -- build owning targets before execution
  build_timeout = 120000,    -- milliseconds per configure/build process
  discovery_timeout = 10000, -- milliseconds per enumeration process
  jobs = 1,                  -- CTest execution parallelism, not build parallelism
  ctest_args = {},           -- additional arguments for registered CTest runs
  frameworks = {},           -- executable path/basename -> "gtest" or "ctest"
  dap = { type = "codelldb" },
  -- root = "/path/to/source", -- optional override, or function(path) -> root
})
```

Options are shared by this adapter instance. Keep `build = true` unless an external build integration guarantees a fresh binary. Setting it to `false` opts out of the automatic build safeguard.

### Build directories and presets

For a preset that writes to `out/debug`, configure the same directory in the adapter:

```lua
require("neotest-cmake")({ build_dir = "out/debug" })
```

For an out-of-tree, multi-config build:

```lua
require("neotest-cmake")({
  root = "/work/project",
  build_dir = "/work/build/project",
  config = "Debug",
})
```

You can return a different directory for each project:

```lua
require("neotest-cmake")({
  build_dir = function(root)
    return root .. "/out/debug"
  end,
})
```

The adapter builds the selected directory with `cmake --build`; it does not read or choose configure/build presets automatically.

<details>
<summary>Integrating an external build tool</summary>

After a successful external build, pass its actual context inside an nvim-nio task:

```lua
require("nio").run(function()
  require("neotest-cmake").discover({
    root = "/path/to/source",
    build_dir = "/path/to/build",
    config = "Debug",
  })
  require("neotest").cmake.refresh("/path/to/source")
end)
```

`discover()` validates File API metadata, enumerates GoogleTests, and remembers the project's build context for this Neovim session. It returns `root`, `build_dir`, `config`, `binaries`, and `cases`. Keep `build_dir` configured appropriately for future sessions.

</details>

## Debugging

Install nvim-dap and configure its debugger adapter using the [nvim-dap documentation](https://github.com/mfussenegger/nvim-dap#installation). The adapter type defaults to `codelldb`; change `dap.type` if your setup uses another type.

Then save and debug the nearest definition or selected parameter:

```lua
vim.cmd("wall")
require("neotest").cmake.run({ strategy = "dap" })
```

Debugging builds first, then launches GoogleTest directly with the selected filter and the registration's working directory/environment. A debug selection must use **one executable with one launch environment**. CTest fixture registrations are rejected: direct debugger launches do not reproduce CTest's fixture lifecycle, timeouts, or expected-failure rules.

## Troubleshooting and limitations

| Symptom | What to check |
| --- | --- |
| No source positions | Verify that the `cpp` parser loads, the extension is supported, and the file uses a recognized GoogleTest macro. |
| Wrong root or no owning target | Set `root`/`build_dir`, confirm the File API reply exists, and list the test source or header in the relevant CMake target. |
| Parameter instances are missing | Build successfully, then use `cmake.run()` or `cmake.refresh(path)` to refresh discovery. Before a successful build, source definitions can appear without concrete instances. |
| Build works in a terminal but fails in Neovim | Check Neovim's `PATH`, compiler/dependency environment, configured build tree, and configuration. |
| An executable is not recognized as GoogleTest | Set `frameworks = { ["unit_tests"] = "gtest" }` using its basename or absolute path. `"ctest"` disables GoogleTest detection for that executable. |
| Selecting one case runs siblings | A whole-executable `add_test()` registration is one CTest execution boundary. Use `gtest_discover_tests()` for per-case selection. |

Additional behavior to be aware of:

- **Normal registered runs use CTest.** Fixtures may add setup/cleanup tests. Grouped registrations retain their policy, and individual GoogleTest output supplies case results inside failed groups.
- **Unregistered runs are direct.** They use an exact GoogleTest filter from the build directory, without CTest fixture or environment properties. Register targets that need those properties.
- **Mixed selections run sequentially.** A CTest batch and direct binaries execute within one Neotest strategy process, with separate captured results. The coordinating headless Neovim process does not load your configuration.
- **Source discovery does not preprocess C++.** Conditionally compiled definitions can remain unmatched and report as skipped. Custom wrapper macros, Qt Test, and generated definitions without source positions are outside the current scope.
- **Custom launchers and `ENVIRONMENT_MODIFICATION` can prevent enumeration.** Enumeration reuses registration arguments, filters, working directories, and `ENVIRONMENT`, but does not reproduce every CTest launch property.
- **Framework detection inspects binaries.** It scans GoogleTest flag strings and shared-library names, up to 64 MiB, rather than launching unknown programs to guess their CLI.
- **A shared source can own multiple executables.** Selecting it runs all matching owners. With `build = false` and no File API metadata, duplicate suite/case names may match unrelated registrations.
- **Extra arguments depend on execution mode.** `ctest_args` applies to registered runs. Neotest's `extra_args` goes to CTest for registered runs and to GoogleTest for direct runs.

## Development

With the Lua dependencies, `cpp` parser, and GoogleTest available:

```sh
make test
```

For measured results and known limitations on upstream Abseil and LevelDB, see [Real-world GoogleTest trials](docs/real-project-trials.md).

The suite uses compiled GoogleTest fixtures and real CMake, CTest, Neotest runners, summary rendering, source signs, and quickfix lists. It covers parameter discovery/selection, independent results, source ownership through linked libraries, stale-binary prevention, failure recovery, and debugger launch specifications. Debugger launch tests do not require a live debugger session.

The runner looks for dependency checkouts under `~/.local/share/nvim/lazy` **only as a development default**. Set `NEOTEST_DEPS` to a directory containing `neotest`, `nvim-nio`, and `plenary.nvim` checkouts when using another layout. Set `CPP_PARSER_DIR` to a runtime directory containing `parser/cpp.so`, and `CMAKE_PREFIX_PATH` if CMake needs help locating GoogleTest. None of these test-runner paths are required for normal plugin use.

## Credits and license

Adapted from [cmake-tests.nvim](https://github.com/mjrogozinski/cmake-tests.nvim), retaining its CTest execution model and GoogleTest/JUnit parsers. Built on [Neotest](https://github.com/nvim-neotest/neotest).

[MIT](LICENSE). The original cmake-tests.nvim copyright is retained.
