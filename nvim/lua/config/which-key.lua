return function ()
  local wk = require('which-key')

  wk.register({
    ["<leader>"] = {
      j = { function () require('telescope.builtin').find_files() end, "Find file" },
      a = { function () require('telescope.builtin').builtin() end, "Telescope" },
      k = { function () require('telescope.builtin').live_grep() end, "Live grep" },
      d = { function () require('telescope.builtin').buffers() end, "Buffers" },
      f = { function () require('telescope').extensions.file_browser.file_browser() end, "File Browser" },
    },
  })

  return {
  }
end
