return function ()
  local saga = require("lspsaga")

  saga.init_lsp_saga({
    symbol_in_winbar = {
      enable = true,
    },
    code_action_lightbulb = {
      virtual_text = false,
    }
  })
end
