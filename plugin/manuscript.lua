-- :Manuscript {export|diff|merge|versions}. Loads the rest the first time it is used.
if vim.g.loaded_manuscript then
  return
end
vim.g.loaded_manuscript = true

local SUBCOMMANDS = {
  build = function(args) require("manuscript.build").run(args) end, -- [part|all|watch] [name.pdf]: the PDF
  clean = function(args) require("manuscript.build").clean(args) end, -- [part|all]: its auxiliary files
  export = function() require("manuscript.export").run() end, -- Word files in export/<date>/
  diff = function(args) require("manuscript.diff").run(args) end, -- [part] [old] [new] [oldkey=newkey ...]
  merge = function(args) require("manuscript.merge").run(args) end, -- a revised Word file back into the sources
  versions = function() require("manuscript.versions").show() end, -- the exports
}
local NAMES = vim.tbl_keys(SUBCOMMANDS)
table.sort(NAMES)

vim.api.nvim_create_user_command("Manuscript", function(o)
  local args = vim.split(o.args, "%s+", { trimempty = true })
  local sub = table.remove(args, 1)
  if not sub then
    return vim.ui.select(NAMES, { prompt = "Manuscript" }, function(choice)
      if choice then
        SUBCOMMANDS[choice]({})
      end
    end)
  elseif not SUBCOMMANDS[sub] then
    return vim.notify("[manuscript] Unknown subcommand: " .. sub, vim.log.levels.ERROR)
  end
  SUBCOMMANDS[sub](vim.tbl_map(vim.fn.expand, args))
end, {
  nargs = "*",
  desc = "manuscript: build [part|all|watch] [name.pdf], clean [part|all], export, diff [part] [old] [new], merge [manuscript] [export.docx], versions",
  complete = function(lead, cmdline)
    local words = vim.split(cmdline:sub(1, #cmdline - #lead), "%s+", { trimempty = true })
    if #words == 1 then
      return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, NAMES)
    elseif words[2] == "diff" then
      local ok, list = pcall(function() return require("manuscript.versions").names() end)
      local all = vim.list_extend(ok and list or {}, vim.fn.getcompletion(lead, "file"))
      return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, all)
    elseif words[2] == "build" or words[2] == "clean" then -- (the parts)
      local ok, project = pcall(require("manuscript.project").find)
      local names = vim.list_extend({ "all" }, ok and vim.tbl_map(function(p) return p.name end, project.parts) or {})
      if words[2] == "build" then
        names[#names + 1] = "watch"
      end
      return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, #words == 2 and names or {})
    elseif words[2] == "merge" then
      return vim.fn.getcompletion(lead, "file")
    end
    return {}
  end,
})
