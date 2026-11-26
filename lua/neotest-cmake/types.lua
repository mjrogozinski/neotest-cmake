---@meta

---@class neotest-cmake.Options
---@field build_dir? string|fun(root: string): string Build directory; defaults to "build" relative to root.
---@field root? string|fun(path: string): string? Override project root detection.
---@field config? string Multi-config configuration, e.g. "Debug"; defaults to "".
---@field cmake? string CMake executable; defaults to "cmake".
---@field ctest? string CTest executable; defaults to "ctest".
---@field build? boolean Build before running; defaults to true.
---@field build_timeout? integer Configure/build timeout in milliseconds; defaults to 120000.
---@field discovery_timeout? integer Enumeration timeout in milliseconds; defaults to 10000.
---@field jobs? integer CTest parallelism; defaults to 1.
---@field frameworks? table<string, 'gtest'|'ctest'> Executable path/basename overrides.
---@field ctest_args? string[] Additional arguments for registered CTest runs.
---@field dap? table Debug adapter configuration; defaults to { type = "codelldb" }.

---@class neotest-cmake.DiscoveryContext
---@field root string Source directory.
---@field build_dir string Build directory.
---@field config? string Multi-config configuration.

---@class neotest-cmake.DiscoveryResult
---@field root string Normalized source directory.
---@field build_dir string Absolute build directory.
---@field config string Selected configuration.
---@field binaries integer Number of discovered GoogleTest binaries.
---@field cases integer Number of distinct cases across binaries.

---@class neotest-cmake.BuildContext
---@field root string
---@field build_dir string
---@field config string
---@field options neotest-cmake.Options
---@field state table Per-configuration caches.
---@field lock table Shared build-directory semaphore.

---@class neotest-cmake.Case
---@field suite string
---@field name string
---@field key string Exact GoogleTest suite.case name.
---@field disabled boolean

---@class neotest-cmake.Registration
---@field kind 'ctest'|'direct'
---@field name string
---@field executable string
---@field command string[]
---@field cwd string
---@field env table<string, string>
---@field properties table<string, any> CTest properties, empty for direct runs.
---@field keys neotest-cmake.Case[]

---@class neotest-cmake.Selection
---@field context neotest-cmake.BuildContext
---@field files table<string, boolean>
---@field affected table<string, boolean>
---@field executables? table<string, boolean>
---@field artifacts string[]
---@field model table[]
---@field targets table[]
---@field stamp? table<string, table|false>

---@class neotest-cmake.Prepared
---@field selection neotest-cmake.Selection
---@field stamp table<string, table|false>
---@field used? boolean One-use handoff to build_spec().
