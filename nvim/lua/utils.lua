local M = {}

function M.system_check(cmd)
  if vim.fn.exepath(cmd) == "" then
    return false
  else
    return true
  end
end

-- Memory available
-- Return memory available in MB
function M.memory_available()
  local mem = vim.fn.system("free -m | awk 'NR==2{printf $7}'")
  return tonumber(mem)
end

return M
