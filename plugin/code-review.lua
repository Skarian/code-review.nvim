if vim.g.loaded_code_review_nvim == 1 then
  return
end
vim.g.loaded_code_review_nvim = 1

require("code-review")._register_commands()
