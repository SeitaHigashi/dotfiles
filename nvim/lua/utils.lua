local M = {}

function M.system_check(cmd)
  if vim.fn.exepath(cmd) == "" then
    return false
  else
    return true
  end
end

return M
