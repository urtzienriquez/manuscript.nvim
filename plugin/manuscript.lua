-- :Manuscript {export|diff|merge|versions}. Loads the rest the first time it is used.
if vim.g.loaded_manuscript then
  return
end
vim.g.loaded_manuscript = true

local SUBCOMMANDS = {
  build = function(args) require("manuscript.build").run(args) end, -- [part|all|watch] [variant] [name.pdf]: the PDF
  clean = function(args) require("manuscript.build").clean(args) end, -- [part|all]: its auxiliary files
  export = function() require("manuscript.export").run() end, -- Word files in export/<date>/
  diff = function(args) require("manuscript.diff").run(args) end, -- [part] [variant] [old] [new] [oldkey=newkey ...]
  merge = function(args) require("manuscript.merge").run(args) end, -- a revised Word file back into the sources
  versions = function() require("manuscript.versions").show() end, -- the exports and submissions
  submit = function(args) require("manuscript.submit").run(args) end, -- [variant] [anonymous|named]: the files for a journal
  new = function(args) require("manuscript.new").run(args) end, -- [template] [folder]: a new manuscript
  respond = function() require("manuscript.respond").run() end, -- the response to the reviewers: response.tex
  archive = function() require("manuscript.archive").run() end, -- the repository's code and data, zipped
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
  desc = "manuscript: build [part|all|watch] [variant] [name.pdf], clean [part|all], export, diff [part] [variant] [old] [new], merge [manuscript] [export.docx], submit [variant] [anonymous|named], new [template] [folder], respond, archive, versions",
  complete = function(lead, cmdline)
    local words = vim.split(cmdline:sub(1, #cmdline - #lead), "%s+", { trimempty = true })
    if #words == 1 then
      return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, NAMES)
    elseif words[2] == "merge" then
      return vim.fn.getcompletion(lead, "file")
    elseif words[2] == "new" then -- (a template, then a folder)
      local names = #words == 2 and vim.tbl_keys(require("manuscript.new").templates()) or vim.fn.getcompletion(lead, "dir")
      table.sort(names)
      return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, names)
    elseif not vim.tbl_contains({ "diff", "build", "clean", "submit" }, words[2]) then
      return {}
    end
    local ok, project = pcall(require("manuscript.project").find)
    local parts = ok and #project.parts > 1 and vim.tbl_map(function(p) return p.name end, project.parts) or {}
    local variants = ok and require("manuscript.variants").names(project) or {}
    if words[2] == "diff" then -- (the parts, the variants, the versions, files)
      local listed, list = pcall(function() return require("manuscript.versions").names() end)
      local all, seen = {}, {}
      for _, n in ipairs(vim.list_extend(vim.list_extend(vim.list_extend(vim.deepcopy(parts), variants), listed and list or {}),
        vim.fn.getcompletion(lead, "file"))) do
        if not seen[n] then
          seen[n], all[#all + 1] = true, n
        end
      end
      return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, all)
    elseif words[2] == "build" then -- (a part or all, then a variant)
      local names = #words == 2 and vim.list_extend(vim.list_extend({ "all", "watch" }, parts), variants) or variants
      return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, names)
    elseif words[2] == "submit" then -- (a variant, then anonymous or named)
      local names = #words == 2 and vim.list_extend(vim.deepcopy(variants), { "anonymous", "named" }) or { "anonymous", "named" }
      return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, names)
    elseif words[2] == "clean" then -- (the parts)
      local names = vim.list_extend({ "all" }, parts)
      return vim.tbl_filter(function(n) return vim.startswith(n, lead) end, #words == 2 and names or {})
    end
    return {}
  end,
})
