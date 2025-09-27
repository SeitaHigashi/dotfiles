return {
  -- DAP settings
  {
    'mfussenegger/nvim-dap',
    event = 'VeryLazy',
  },
  {
    'jay-babu/mason-nvim-dap.nvim',
    dependencies = {
      'williamboman/mason.nvim',
      'mfussenegger/nvim-dap',
    },
    event = 'VeryLazy',
    opts = {
      handlers = {},
    },
  },
  {
    'nvim-neotest/nvim-nio',
  },
  {
    'rcarriga/nvim-dap-ui',
    event = 'VeryLazy',
    dependencies = {
      'mfussenegger/nvim-dap',
      'nvim-neotest/nvim-nio',
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
  },
  {
    'nvim-telescope/telescope-dap.nvim',
    dependencies = {
      'mfussenegger/nvim-dap',
      'nvim-telescope/telescope.nvim',
    },
  }
}
