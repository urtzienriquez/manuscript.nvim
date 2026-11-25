-- nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests {minimal_init='tests/minimal_init.lua'}"
-- (neoffice.nvim and plenary.nvim: beside this plugin, in $NEOFFICE_DIR / $PLENARY_DIR, or installed)
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local function add(env, candidates)
  for _, dir in ipairs(vim.list_extend({ vim.env[env] or "" }, candidates)) do
    if dir ~= "" and vim.fn.isdirectory(dir) == 1 then
      vim.opt.rtp:append(dir)
      return
    end
  end
end
add("NEOFFICE_DIR", { root .. "/../neoffice.nvim", vim.fn.stdpath("data") .. "/site/pack/core/opt/neoffice.nvim" })
add("PLENARY_DIR", {
  vim.fn.stdpath("data") .. "/site/pack/core/opt/plenary.nvim",
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  vim.fn.stdpath("data") .. "/site/pack/test/start/plenary.nvim",
})
vim.cmd("runtime plugin/plenary.vim")
vim.cmd("runtime plugin/neoffice.lua")
vim.cmd("runtime plugin/manuscript.lua")
-- (what the plugin remembers: in temporary files, not the user's)
require("manuscript.build").times = vim.fn.tempname() .. "-build-times.json"
require("manuscript.project").memory = vim.fn.tempname() .. "-projects.json"
