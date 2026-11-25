-- The standalone LaTeX figures of a manuscript (figures_manuscript/fig1.tex, a document of its own
-- that makes fig1.pdf, which the manuscript includes): built before the manuscript's LaTeX, when
-- they changed. Found by themselves: each \includegraphics{X} (in an .Rmd, also ![...](X) and
-- knitr::include_graphics("X")) whose PDF has a .tex beside it that is a document. The option
-- `figures`: true (that), false (never), or a list of globs of more of them (relative to the
-- manuscript's folder).
local job = require("manuscript.job")
local project_ = require("manuscript.project")
local M = {}

local function is_document(path)
  return (project_.read(path) or ""):find("\\begin%s*{document}") ~= nil
end

-- The figures: { tex, pdf, name }, in the order found.
function M.find(project)
  local option = project.options.figures
  if option == false then
    return {}
  end
  local out, seen = {}, {}
  local function add(tex)
    tex = vim.fs.normalize(tex)
    if not seen[tex] and vim.uv.fs_stat(tex) and is_document(tex) then
      seen[tex] = true
      out[#out + 1] = { tex = tex, pdf = (tex:gsub("%.tex$", ".pdf")), name = vim.fs.basename(tex):gsub("%.tex$", "") }
    end
  end
  local function included(name)
    name = vim.trim(name)
    if name:match("%.pdf$") or not name:match("%.%w+$") then
      local path = name:sub(1, 1) == "/" and name or vim.fs.joinpath(project.dir, name)
      add((path:gsub("%.pdf$", "")) .. ".tex")
    end
  end
  for _, file in ipairs(project.files) do
    local text = project_.read(file) or ""
    for after in text:gmatch("\\includegraphics()") do -- (in order; with options or not)
      local name = text:match("^%s*%b[]%s*{([^}]+)}", after) or text:match("^%s*{([^}]+)}", after)
      if name then
        included(name)
      end
    end
    if project_.kind(file) == "rmd" then
      for name in text:gmatch("!%b[]%(%s*([^)%s]+)") do
        included(name)
      end
      for name in text:gmatch("include_graphics%(%s*['\"]([^'\"]+)['\"]") do
        included(name)
      end
    end
  end
  if type(option) == "table" then
    for _, pattern in ipairs(option) do
      for _, tex in ipairs(vim.fn.glob(vim.fs.joinpath(project.dir, pattern), false, true)) do
        add(tex)
      end
    end
  end
  return out
end

local function mtime(path)
  local st = vim.uv.fs_stat(path)
  return st and st.mtime.sec + st.mtime.nsec / 1e9
end

-- Whether a figure must be built: no PDF, or one older than its .tex or than a file of its own it
-- read when it was last built (the panels, in its .fls; not TeX's own files).
function M.stale(fig)
  local made = mtime(fig.pdf)
  if not made or (mtime(fig.tex) or 0) > made then
    return true
  end
  local dir = vim.fs.dirname(fig.tex)
  for line in (project_.read((fig.tex:gsub("%.tex$", ".fls"))) or ""):gmatch("[^\n]+") do
    local input = line:match("^INPUT (.+)$")
    if input and not input:match("/texmf") and not input:match("/texlive/") and not input:match("%.aux$") then
      local path = input:sub(1, 1) == "/" and input or vim.fs.joinpath(dir, input)
      local t = mtime(path)
      if t and t > made then
        return true
      end
    end
  end
  return false
end

local FLAG = { pdflatex = "-pdf", xelatex = "-xelatex", lualatex = "-lualatex" }

-- Its engine: its "% !TeX program = xelatex" line; else the one that built it last (its .log: a
-- figure made by hand or by a Makefile stays as it was made); else pdfLaTeX, the usual for a
-- standalone figure, or LuaLaTeX if it loads fontspec (or unicode-math), which pdfLaTeX can't.
-- (Not the manuscript's: a pdfLaTeX figure, with fontenc T1, gets wrong glyphs in LuaLaTeX.)
function M.engine(fig, project)
  local text = project_.read(fig.tex) or ""
  local n = 0
  for line in text:gmatch("[^\n]*") do
    local program = line:match("^%%%s*!%a+%s+program%s*=%s*(%a+)")
    if program and FLAG[program:lower()] then
      return program:lower()
    end
    n = n + 1
    if n > 10 then
      break
    end
  end
  local log = (project_.read((fig.tex:gsub("%.tex$", ".log"))) or ""):match("^[^\n]*") or ""
  if log:match("^This is LuaH?B?TeX") then
    return "lualatex"
  elseif log:match("^This is XeTeX") then
    return "xelatex"
  elseif log:match("^This is pdfTeX") then
    return "pdflatex"
  end
  local preamble = (text:match("^(.-)\\begin%s*{document}") or text):gsub("%%[^\n]*", "")
  if preamble:find("\\usepackage%s*%b[]%s*{[^}]*fontspec") or preamble:find("\\usepackage%s*{[^}]*fontspec")
    or preamble:find("{[^}]*unicode%-math") then
    return "lualatex"
  end
  return "pdflatex"
end

-- In a task: builds the figures that changed. Stops with their LaTeX errors (in the quickfix list).
function M.update(project)
  for _, fig in ipairs(M.find(project)) do
    if M.stale(fig) then
      job.say("figure " .. fig.name)
      local engine = M.engine(fig, project)
      local dir = vim.fs.dirname(fig.tex)
      local r = job.run({ "latexmk", FLAG[engine] or "-pdf", "-interaction=nonstopmode", vim.fs.basename(fig.tex) }, { cwd = dir })
      local build = require("manuscript.build")
      local errors = build.errors((fig.tex:gsub("%.tex$", ".log")), fig.tex)
      if #errors > 0 then
        if vim.uv.fs_stat(fig.pdf) then -- (a PDF made with errors: rebuilt next time, not taken as up to date)
          vim.uv.fs_utime(fig.pdf, 0, 0)
        end
        build.show(errors, "manuscript build: figure " .. fig.name)
        job.fail(("figure %s has LaTeX errors: %d in the quickfix list"):format(fig.name, #errors))
      elseif r.code ~= 0 and not vim.uv.fs_stat(fig.pdf) then
        job.fail(("figure %s: no PDF made\n%s"):format(fig.name, job.tail(r)))
      end
    end
  end
end

-- Removes their auxiliary files (latexmk -c: the PDFs stay); the names of those cleaned.
function M.clean(project)
  local cleaned = {}
  for _, fig in ipairs(M.find(project)) do
    if vim.uv.fs_stat((fig.tex:gsub("%.tex$", ".fdb_latexmk"))) then
      vim.system({ "latexmk", "-c", vim.fs.basename(fig.tex) }, { cwd = vim.fs.dirname(fig.tex) }):wait()
      cleaned[#cleaned + 1] = fig.name .. ".*"
    end
  end
  return cleaned
end

return M
