local system_check = function (cmd)
  if vim.fn.exepath(cmd) == "" then
    return false
  else
    return true
  end
end

return {
  system_check = system_check
}
