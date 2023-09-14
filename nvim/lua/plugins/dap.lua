return {
  -- DAP settings
  {
    'mfussenegger/nvim-dap',
    event = 'VeryLazy',
  },
  {
    'jay-babu/mason-nvim-dap.nvim',
    depends = {
      'williamboman/mason.nvim',
      'mfussenegger/nvim-dap',
    },
    event = 'VeryLazy',
    opts = {
      handlers = {},
    },
  },
  {
    'rcarriga/nvim-dap-ui',
    event = 'VeryLazy',
    depends = {
      'mfussenegger/nvim-dap',
    },
    opts = function ()
      local dap, dapui = require("dap"), require("dapui")
      dap.listeners.after.event_initialized["dapui_config"] = function()
        dapui.open()
      end
      dap.listeners.before.event_terminated["dapui_config"] = function()
        dapui.close()
      end
      dap.listeners.before.event_exited["dapui_config"] = function()
        dapui.close()
      end
      return {}
    end
  }
}
