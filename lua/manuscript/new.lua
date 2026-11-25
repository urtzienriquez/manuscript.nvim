-- :Manuscript new [template] [folder]: a new manuscript, from a template: the plugin's (rnw, rmd,
-- tex, jnw: a paper of a main text and an appendix, with the switches of the variants, a title
-- page and a cover letter), or yours (the folders of the option `templates`, which win by name).
local M = {}

-- { [name] = folder } of the templates.
function M.templates()
  local out = {}
  local function add(base)
    for name, kind in vim.fs.dir(base) do
      if kind == "directory" and not name:match("^%.") then
        out[name] = vim.fs.joinpath(base, name)
      end
    end
  end
  add(require("manuscript").path("templates"))
  local own = require("manuscript").config.templates
  if own then
    add(vim.fs.normalize(vim.fn.expand(own)))
  end
  return out
end

-- Copies `from` into `to` (new, or empty), but .git and the template's own README (about it, not
-- the paper).
local function copy(from, to)
  for rel, kind in vim.fs.dir(from, { depth = math.huge, skip = function(name) return name ~= ".git" end }) do
    if rel:match("^README") or rel == ".git" or rel:match("^%.git/") then
      goto next
    end
    local a, b = vim.fs.joinpath(from, rel), vim.fs.joinpath(to, rel)
    if kind == "directory" then
      vim.fn.mkdir(b, "p")
    elseif kind == "file" then
      vim.fn.mkdir(vim.fs.dirname(b), "p")
      assert(vim.uv.fs_copyfile(a, b))
    end
    ::next::
  end
end

function M.run(args)
  local templates = M.templates()
  local names = vim.tbl_keys(templates)
  table.sort(names)
  local function make(name, folder)
    local from = templates[name]
    if not from then
      return vim.notify(("[manuscript] No template %s (the templates: %s)"):format(name, table.concat(names, ", ")), vim.log.levels.ERROR)
    end
    local to = vim.fs.normalize(vim.fn.fnamemodify(folder or "manuscript", ":p"))
    if vim.uv.fs_stat(to) and #vim.fn.readdir(to) > 0 then
      return vim.notify(("[manuscript] %s isn't empty: a new manuscript goes in a new folder"):format(vim.fn.fnamemodify(to, ":~")), vim.log.levels.ERROR)
    end
    copy(from, to)
    local ok, root = pcall(require("manuscript.project").root, to)
    if ok and root then
      vim.cmd.edit(vim.fn.fnameescape(root))
    end
    vim.notify(("[manuscript] New manuscript in %s, from %s"):format(vim.fn.fnamemodify(to, ":~:."), name))
  end
  if args[1] then
    return make(args[1], args[2])
  end
  vim.ui.select(names, { prompt = "Template" }, function(name)
    if name then
      make(name, nil)
    end
  end)
end

return M
