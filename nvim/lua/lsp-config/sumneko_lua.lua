local runtime_path = vim.split(package.path, ";")
table.insert(runtime_path, "lua/?.lua")
table.insert(runtime_path, "lua/?/init.lua")

return {
  Lua = {
    diagnostics = {
      globals = {
        "vim"
      }
    }
  },
  runtime = {
    path = runtime_path
  }
}
