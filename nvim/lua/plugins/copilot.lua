return {
  {
    'zbirenbaum/copilot.lua',
    cmd = 'Copilot',
    event = 'InsertEnter',
    config = {
      suggestion = { enabled = false },
      panel = {
        enabled = false,
        layout = {
          position = 'right',
          ratio = 0.3,
        }
      }
    }
  },

  {
    'zbirenbaum/copilot-cmp',
    event = 'InsertEnter',
    config = {}
  }
}
