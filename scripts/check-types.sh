#!/bin/sh
set -eu
: "${NVIM:=nvim}"
: "${LUA_LANGUAGE_SERVER:=lua-language-server}"
VIMRUNTIME="$("$NVIM" --clean --headless -i NONE '+lua io.write(vim.env.VIMRUNTIME)' +qa)"
export VIMRUNTIME
# Check project code, not tools installed into the workspace by CI.
for directory in lua tests; do
  "$LUA_LANGUAGE_SERVER" --check="$(pwd)/$directory" --configpath="$(pwd)/.luarc.json" --checklevel=Error --logpath=build/luals
done
