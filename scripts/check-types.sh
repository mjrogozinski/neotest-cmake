#!/bin/sh
set -eu
: "${NVIM:=nvim}"
: "${LUA_LANGUAGE_SERVER:=lua-language-server}"
VIMRUNTIME="$("$NVIM" --clean --headless -i NONE '+lua io.write(vim.env.VIMRUNTIME)' +qa)"
export VIMRUNTIME
"$LUA_LANGUAGE_SERVER" --check="$(pwd)" --configpath="$(pwd)/.luarc.json" --checklevel=Error --logpath=build/luals
