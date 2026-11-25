-- :Manuscript export: Word files of the manuscript, one per part (main, appendix1...), in a new
-- folder export/<date>/ beside the root. What toword did: knit, make the LaTeX readable by pandoc
-- (prepare.lua), convert with pandoc (citeproc, the filters in filters/, a reference .docx), and
-- align the author block. The intermediate files stay in Neovim's cache, never in your folder.
--
-- Each export is a snapshot of what was sent (see snapshot.lua): its Word files, and in .manuscript/
-- the LaTeX they were made from, which merge and diff use.
local job = require("manuscript.job")
local project_ = require("manuscript.project")
local plugin = require("manuscript")
local M = {}

local function write(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

-- A folder of its own in Neovim's cache, for the files made on the way.
function M.cache(project, what)
  local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "manuscript", vim.fn.sha256(project.root):sub(1, 12), what)
  vim.fn.mkdir(dir, "p")
  return dir
end

-- export/<date>/ (or <date>-2, -3... for another export that day), new.
function M.new_folder(project)
  local base = vim.fs.joinpath(project.dir, project.options.export_dir)
  vim.fn.mkdir(base, "p")
  if not vim.uv.fs_stat(vim.fs.joinpath(base, ".gitignore")) then -- (the exports stay out of git)
    write(vim.fs.joinpath(base, ".gitignore"), "*\n")
  end
  local name, n = os.date("%Y-%m-%d"), 1
  while vim.uv.fs_stat(vim.fs.joinpath(base, n == 1 and name or name .. "-" .. n)) do
    n = n + 1
  end
  local dir = vim.fs.joinpath(base, n == 1 and name or name .. "-" .. n)
  vim.fn.mkdir(vim.fs.joinpath(dir, ".manuscript"), "p")
  return dir
end

-- The citation style: the option, else a .csl in the manuscript's folder, else the bundled one.
local function csl(project)
  if project.options.csl then
    return vim.fs.normalize(vim.fs.joinpath(project.dir, project.options.csl))
  end
  local own = vim.tbl_filter(function(name) return name:match("%.csl$") end, vim.fn.readdir(project.dir))
  return own[1] and vim.fs.joinpath(project.dir, own[1]) or plugin.path("assets", "global-ecology-and-biogeography.csl")
end

-- Pictures given with a path relative to the manuscript's folder: with their full path (pandoc
-- runs elsewhere).
local function absolute_pictures(text, dir)
  local function absolute(head, path, tail)
    if path:match("^/") or path:match("^~") then
      return head .. path .. tail
    end
    local full = vim.fs.normalize(vim.fs.joinpath(dir, path))
    return head .. (vim.uv.fs_stat(full) and full or path) .. tail
  end
  text = text:gsub("(\\includegraphics%s*%b[]%s*{)([^}]+)(})", absolute) -- (with options)
  return (text:gsub("(\\includegraphics%s*{)([^}]+)(})", absolute))
end

-- The finishing touches to a Word file pandoc wrote:
-- - the author block (the first two paragraphs with superscripts: the authors, then their
--   affiliations): centred, then left-aligned, as toword did (which also gave the paragraphs after
--   them an empty alignment: not here, Word's files don't allow that);
-- - the pictures' descriptions, where pandoc writes the path of their file: only its name (your
--   folders aren't for the people you send it to).
function M.finish(docx)
  local zip, xml = require("neoffice.zip"), require("neoffice.xml")
  local root = xml.parse(assert(zip.read(docx, "word/document.xml")))
  local changed = false
  for _, el in ipairs(xml.collect(root, { ["pic:cNvPr"] = true, ["wp:docPr"] = true })) do
    local descr = xml.attr(el, "descr")
    if descr and descr:find("/", 1, true) then
      xml.set_attr(el, "descr", vim.fs.basename(descr))
      changed = true
    end
  end
  local n = 0
  for _, p in ipairs(xml.collect(root, { ["w:p"] = true })) do
    if n < 2 and xml.find(p, "w:vertAlign") then
      n = n + 1
      local ppr = xml.child(p, "w:pPr") or xml.append(p, xml.elem("w:pPr"), 1)
      local jc = xml.child(ppr, "w:jc") or xml.append(ppr, xml.elem("w:jc"))
      xml.set_attr(jc, "w:val", n == 1 and "center" or "left")
    end
  end
  if n > 0 or changed then
    zip.write(docx, { ["word/document.xml"] = xml.serialize(root) })
  end
end

-- A part's LaTeX (knitted) into a Word file.
function M.convert(project, name, tex, docx, cache)
  local options = project.options
  local prepare = require("manuscript.prepare")
  local text = project_.read(tex)
  local prepared = prepare.prepare(text, {
    name = name,
    repo = vim.fs.dirname(project.dir), -- (for "{../figures": see prepare.lua)
    tikz = function(code, base) return prepare.render_tikz(code, base, cache) end,
  })
  local input = vim.fs.joinpath(cache, name .. "_processed.tex")
  write(input, absolute_pictures(prepared, project.dir))
  local cmd = { "pandoc", input }
  -- (the .bib and .csl files by their names, copied beside: pandoc writes them in the Word file)
  local function here(path)
    assert(vim.uv.fs_copyfile(path, vim.fs.joinpath(cache, vim.fs.basename(path))))
    return vim.fs.basename(path)
  end
  local bibs = vim.tbl_filter(function(p) return vim.uv.fs_stat(p) ~= nil end, project_.bibs(text, project.dir))
  for _, bib in ipairs(#bibs > 0 and bibs or project.bibs) do
    cmd[#cmd + 1] = "--bibliography=" .. here(bib)
  end
  local function filter(file)
    vim.list_extend(cmd, { "--lua-filter", plugin.path("filters", file) })
  end
  filter("refsection-bibliographies.lua")
  vim.list_extend(cmd, { "--csl", here(csl(project)) })
  for _, file in ipairs({ "crossref.lua", "fix-inner-parens.lua", "fix-titleblock.lua", "code-block-lang.lua" }) do
    filter(file)
  end
  vim.list_extend(cmd, { "--highlight-style", "tango" })
  if options.move_figures then
    filter("move-figures.lua")
  end
  if options.move_tables then
    filter("move-tables.lua")
  end
  filter("tikz-to-image.lua")
  filter("pdf-to-png.lua")
  local reference = options.reference_docx and vim.fs.normalize(vim.fs.joinpath(project.dir, options.reference_docx))
    or plugin.path("assets", "reference.docx")
  vim.list_extend(cmd, { "--reference-doc=" .. reference, "--resource-path=" .. cache .. ":" .. project.dir, "-o", docx })
  local r = job.run(cmd, { cwd = cache, env = { TOWORD_DPI = tostring(options.dpi) } })
  if r.code ~= 0 then
    job.fail(("pandoc couldn't convert %s:\n%s"):format(name, job.tail(r)))
  end
  M.finish(docx)
end

-- :Manuscript export; on_done(ok) when it ends.
function M.run(on_done)
  job.task(function()
    local project = project_.find()
    job.need("pandoc", "to make Word files")
    local cache = M.cache(project, "export")
    local texs = require("manuscript.knit").parts(project, cache)
    local folder = M.new_folder(project)
    local made, files = {}, {}
    job.range(80, 100)
    for k, part in ipairs(project.parts) do
      job.say(("converting %s (%d/%d)"):format(part.name, k, #project.parts), math.floor((k - 1) / #project.parts * 100))
      local file = ("%s_%s.docx"):format(part.name, vim.fs.basename(folder)) -- (main_2026-11-25.docx: a version)
      M.convert(project, part.name, texs[part.name], vim.fs.joinpath(folder, file), cache)
      made[#made + 1], files[part.name] = file, file
    end
    require("manuscript.snapshot").record(project, folder, texs, files)
    vim.schedule(function() project_.remember(project.root) end)
    job.say(("exported to %s: %s"):format(vim.fn.fnamemodify(folder, ":~:."), table.concat(made, ", ")))
  end, on_done, "export")
end

return M
