-- The LaTeX of a manuscript: an .Rnw or .Rmd root is knitted (knitrmini, or knitr; an .Rmd with an
-- output format in its YAML header: rendered by rmarkdown), a .jnw one by Knit.jl (the Julia worker),
-- one part at a time as you would by hand: a copy of the root with only
-- that part's child chunk evaluated. A .tex root is its own LaTeX (a part: a copy without the other
-- parts). What leaves the folder is flattened (its \input{}s inlined).
--
-- Copies of the root are written beside it (_manuscript-<part>.Rnw: knitting must run where the
-- root is, for its relative paths; a name starting with "." can't be compiled, as TeX doesn't write
-- such files), and removed with all they produced.
local job = require("manuscript.job")
local project_ = require("manuscript.project")
local M = {}

local PREFIX = "_manuscript-"

-- The root with only `part`'s child chunk evaluated (all of them when part is nil): an .Rnw's
-- <<..., child='x'>>= or an .Rmd's ```{r ..., child="x"}.
function M.root_for(text, part_file, dir)
  return (text:gsub("[^\n]+", function(line)
    local child, options = project_.child_of(line)
    if not child then
      return line
    end
    local on = not part_file or vim.fs.normalize(vim.fs.joinpath(dir, child)) == part_file
    local rest = options:gsub(",?%s*eval%s*=%s*[^,]+", ""):gsub("^%s*,%s*", ""):gsub("%s*,%s*$", "")
    local eval = "eval=" .. (on and "TRUE" or "FALSE")
    if line:match("^%s*<<") then
      return line:match("^%s*") .. "<<" .. rest .. ", " .. eval .. ">>="
    end
    return line:match("^%s*```+") .. "{r" .. (rest ~= "" and " " .. rest .. ", " or ", ") .. eval .. "}"
  end))
end

local installed -- (what R has: { knitrmini, rmd (knitrmini knits .Rmd), serve (its worker) }; asked once)
local function r_has()
  if not installed then
    local r = job.run({ "Rscript", "-e", 'k <- requireNamespace("knitrmini", quietly = TRUE); '
      .. 'n <- if (k) asNamespace("knitrmini"); '
      .. 'cat(k, k && exists("render_markdown_latex", n), k && exists("serve", n))' })
    local k, rmd, serve = (r.stdout or ""):match("(%a+)%s+(%a+)%s+(%a+)%s*$")
    installed = { knitrmini = k == "TRUE", rmd = rmd == "TRUE", serve = serve == "TRUE" }
  end
  return installed
end

-- How a manuscript is knitted ("latex" for a .tex one: it isn't): its option `knit`, else Knit.jl
-- for .jnw; for .Rmd, rmarkdown if its
-- YAML header asks for an output format (output:, as rmarkdown does), else knitrmini (if it knits
-- .Rmd); for .Rnw, knitrmini if installed, else knitr.
local function knitter(project)
  if project.kind == "tex" then -- (just LaTeX)
    return "latex"
  elseif project.options.knit then
    return project.options.knit
  elseif project.kind == "jnw" then
    return "knit.jl"
  elseif project.kind == "rmd" then
    local header = (project_.read(project.root) or ""):match("^%-%-%-%s*\n(.-)\n%-%-%-") or ""
    if ("\n" .. header):find("\noutput%s*:") or not r_has().rmd then
      return "rmarkdown"
    end
    return "knitrmini"
  end
  return r_has().knitrmini and "knitrmini" or "knitr"
end

M.knitter = knitter

-- Removes what the copies of the root produced (files, and knitr's folders of figures).
function M.clean(dir)
  for name, kind in vim.fs.dir(dir) do
    if vim.startswith(name, PREFIX) then
      if kind == "directory" then
        vim.fn.delete(vim.fs.joinpath(dir, name), "rf")
      else
        os.remove(vim.fs.joinpath(dir, name))
      end
    end
  end
end

-- The LaTeX engine of a manuscript: an .Rmd's (latex_engine: in its YAML header), else the option.
function M.engine(project)
  if project.kind == "rmd" then
    local header = (project_.read(project.root) or ""):match("^%-%-%-%s*\n(.-)\n%-%-%-") or ""
    local named = header:match("latex_engine:%s*['\"]?(%a+)")
    if named == "pdflatex" or named == "xelatex" or named == "lualatex" then
      return named
    end
  end
  return project.options.latex
end

-- Renders `name`'s copy of an .Rmd root (only `part_file`'s child, or all) into `out` (a .tex, beside
-- the root): with the format of its YAML header if it makes PDFs (its template, citation package,
-- cross-references...), else rmarkdown::pdf_document; and no LaTeX: rmarkdown runs none for a .tex
-- output, and bookdown's (which runs it anyway, after resolving \@ref(), and then deletes the .tex
-- unless keep_tex) is skipped in this R session, the .tex kept. Knitr's figures stay until the
-- copies are cleaned. text: the root's text instead of the root's; on_line: each line it prints.
function M.render(project, name, part_file, out, text, on_line)
  job.need("Rscript", "to render .Rmd files")
  local copy = PREFIX .. name .. ".Rmd"
  local f = assert(io.open(vim.fs.joinpath(project.dir, copy), "w"))
  f:write(M.root_for(text or project_.read(project.root), part_file, project.dir))
  f:close()
  local expr = table.concat({
    'assignInNamespace("latexmk", function(...) invisible(NULL), "tinytex")', -- (bookdown's LaTeX: not here)
    ("f <- %q"):format(copy),
    'fmt <- rmarkdown::default_output_format(f)$name',
    'if (!grepl("pdf|latex|beamer", fmt)) fmt <- "rmarkdown::pdf_document"',
    'a <- tryCatch(names(formals(if (grepl("::", fmt)) eval(parse(text = fmt)) else get(fmt, envir = asNamespace("rmarkdown")))), error = function(e) character())',
    'oo <- if (any(c("keep_tex", "...") %in% a)) list(keep_tex = TRUE)',
    ("tex <- %q"):format(vim.fs.basename(out)),
    -- (bookdown then names a PDF it didn't make, and render stops on it: the .tex is made, all right)
    'tryCatch(invisible(rmarkdown::render(f, output_format = fmt, output_file = tex, output_options = oo, clean = FALSE, quiet = FALSE)), '
      .. 'error = function(e) if (!(file.exists(tex) && grepl("does not exist", conditionMessage(e)))) stop(e))',
  }, "; ")
  local made = vim.fs.joinpath(project.dir, vim.fs.basename(out))
  os.remove(made) -- (a .tex there after it: this one's)
  local r = job.run({ "Rscript", "-e", expr }, { cwd = project.dir, line = on_line })
  if r.code ~= 0 or not vim.uv.fs_stat(made) then
    job.fail(("rendering %s failed:\n%s"):format(name, job.tail(r)))
  end
  if made ~= out then
    assert(vim.uv.fs_copyfile(made, out))
  end
  return r
end

-- A .tex root's part as a document of its own: `_manuscript-<name>.tex` beside the root, the root
-- with the other parts' \include{}s left out (all of them, for the root's own text) and this one's
-- as \input{}, flattened, its references to other parts numbered from the whole's build. Returns
-- its name. text: the root's text instead of the root's.
function M.tex_part(project, part, name, text)
  text = text or project_.read(project.root) or ""
  local own = part.file == project.root
  local before, body, after = text:match("^(.-\\begin%s*{document}[^\n]*\n)(.-)(\\end%s*{document}.*)$")
  if body then
    local lines = {}
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
      local this = false
      line = line:gsub("\\include%s*{([^}]+)}", function(included)
        local file = vim.fs.normalize(vim.fs.joinpath(project.dir, included))
        file = file:match("%.tex$") and file or file .. ".tex"
        this = this or file == part.file
        return file == part.file and not own and ("\\input{" .. included .. "}") or ""
      end)
      -- (another part's: the root's own text, its \input{}s, go; commands that show no text stay)
      if own or this or not project_.shows_text(line) then
        lines[#lines + 1] = line
      end
    end
    text = before .. table.concat(lines, "\n") .. "\n" .. after
  end
  local copy = PREFIX .. name .. ".tex"
  local path = vim.fs.joinpath(project.dir, copy)
  local f = assert(io.open(path, "wb"))
  f:write(project_.flatten(text, project.dir))
  f:close()
  require("manuscript.labels").resolve_file(path, require("manuscript.labels").snapshot(project))
  return copy
end

local EXT = { rnw = ".Rnw", rmd = ".Rmd", jnw = ".jnw" }

-- Knits `name`'s copy of the root (only `part_file`, or all if nil) into `out`, with knitrmini or
-- knitr (in R), or Knit.jl (in the Julia worker); compile: also builds the PDF (in the root's
-- folder, under the copy's name: its label snapshot). text: the root's text instead of the root's;
-- on_line: each line it prints (then not quiet: its chunks, LaTeX, for the progress).
local function knit(project, name, part_file, out, compile, text, on_line)
  text = text or project_.read(project.root)
  local copy = PREFIX .. name .. EXT[project.kind]
  local f = assert(io.open(vim.fs.joinpath(project.dir, copy), "w"))
  f:write(M.root_for(text, part_file, project.dir))
  f:close()
  -- (the labels of the whole, for references to other parts: an export's, or a build's)
  local snapshot = vim.fs.joinpath(project.dir, PREFIX .. "all-labels.aux")
  if not vim.uv.fs_stat(snapshot) then
    snapshot = require("manuscript.labels").snapshot(project)
  end
  if name ~= "all" and vim.uv.fs_stat(snapshot) then
    vim.uv.fs_copyfile(snapshot, vim.fs.joinpath(project.dir, PREFIX .. name .. "-labels.aux"))
  end
  local how = knitter(project)
  if how == "knit.jl" then
    return require("manuscript.worker").knit(project, vim.fs.joinpath(project.dir, copy), out, compile, M.engine(project), on_line)
  elseif how == "knitrmini" and project.options.r_worker ~= false and r_has().serve then -- (R started once)
    return require("manuscript.worker").knit(project, vim.fs.joinpath(project.dir, copy), out, compile, M.engine(project), on_line, "r")
  end
  job.need("Rscript", "to knit " .. vim.fs.basename(project.root))
  local quiet = on_line and "FALSE" or "TRUE"
  local expr
  if how == "knitrmini" then
    expr = ("knitrmini::knit(%q, output = %q, compile = %s, engine = %q, quiet = %s)"):format(copy, out,
      compile and "TRUE" or "FALSE", M.engine(project), quiet)
  else
    expr = ("knitr::knit(%q, output = %q, quiet = %s)"):format(copy, out, quiet)
  end
  local r = job.run({ "Rscript", "-e", expr }, { cwd = project.dir, line = on_line,
    env = { KNITRMINI_FIG_PATH = require("manuscript.worker").FIG_PATH } }) -- (chunks' figures: in .build/)
  local made = vim.uv.fs_stat(vim.fs.joinpath(project.dir, out)) or vim.uv.fs_stat(out)
  if not made or (r.code ~= 0 and not (r.stderr or ""):find("PDF not produced", 1, true)) then
    job.fail(("knitting %s failed:\n%s"):format(name, job.tail(r)))
  end
  return r
end

M.knit = knit

-- Whether a file is newer than all the sources of the manuscript (its files and .bib).
function M.fresh(project, file)
  local st = vim.uv.fs_stat(file)
  if not st then
    return false
  end
  for _, f in ipairs(vim.list_extend(vim.deepcopy(project.files), project.bibs)) do
    local s = vim.uv.fs_stat(f)
    if s and (s.mtime.sec > st.mtime.sec or s.mtime.sec == st.mtime.sec and s.mtime.nsec > st.mtime.nsec) then
      return false
    end
  end
  return true
end

local function write(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

-- A LaTeX file with what it \input{}s inlined: readable anywhere (pandoc, latexdiff in the cache).
local function flatten_file(project, path)
  local text = project_.read(path) or ""
  local flat = project_.flatten(text, project.dir)
  if flat ~= text then
    write(path, flat)
  end
end

-- A copy's figures (a folder named after it: rmarkdown's <copy>_files, Knit.jl's <copy>_figures):
-- moved beside `out`, which then names them there (the copy's folder goes with the copies).
local function keep_figures(project, name, out)
  for _, suffix in ipairs({ "_files", "_figures" }) do
    local folder = PREFIX .. name .. suffix
    local from = vim.fs.joinpath(project.dir, folder)
    if vim.uv.fs_stat(from) then
      local to = (out:gsub("%.tex$", "")) .. suffix
      vim.fn.delete(to, "rf")
      if not vim.uv.fs_rename(from, to) then -- (another file system)
        vim.system({ "cp", "-r", from, to }):wait()
      end
      local text = project_.read(out) or ""
      local target = (to:gsub("%%", "%%%%")) .. "/"
      local moved = text:gsub(vim.pesc(from .. "/"), target):gsub(vim.pesc(folder .. "/"), target) -- (absolute, relative)
      if moved ~= text then
        write(out, moved)
      end
    end
  end
end

-- The LaTeX (no PDF) of the whole (part_file nil) or of a part, into `out`, flattened. name: its
-- copies' (see knit, render, tex_part); text: the root's text instead of the root's (an old
-- version's, whose part_file is then its copy).
local function latex(project, name, part_file, out, text)
  local whole_aux = require("manuscript.labels").snapshot(project) -- (the whole's labels)
  if project.kind == "tex" then
    if not part_file or #project.parts < 2 then
      write(out, text or project_.read(project.root) or "")
    else
      local part = vim.iter(project.parts):find(function(p) return p.file == part_file end) or { name = name, file = part_file }
      assert(vim.uv.fs_copyfile(vim.fs.joinpath(project.dir, M.tex_part(project, part, name, text)), out))
    end
  elseif knitter(project) == "rmarkdown" then
    M.render(project, name, part_file, out, text)
    keep_figures(project, name, out)
    if part_file then
      require("manuscript.labels").resolve_file(out, whole_aux)
    end
  else
    knit(project, name, part_file, out, false, text)
    keep_figures(project, name, out) -- (knitr's figures of an .Rmd copy)
    if part_file and knitter(project) == "knitr" then -- (knitrmini and Knit.jl resolve them themselves)
      require("manuscript.labels").resolve_file(out, whole_aux)
    end
  end
  flatten_file(project, out)
end

-- The LaTeX of the whole manuscript into `out` (no PDF). text: the root's text to knit instead of
-- the root's (an old version's: see diff.lua).
function M.whole(project, out, text)
  local ok, err = pcall(latex, project, "all", nil, out, text)
  M.clean(project.dir)
  if not ok then
    error(err, 0)
  end
  return out
end

-- The LaTeX of one part (`part_file`: its file, as the root names it) into `out` (no PDF). text:
-- the root's text to knit instead of the root's (an old version's).
function M.one(project, part_file, out, text)
  local ok, err = pcall(latex, project, "part", part_file, out, text)
  M.clean(project.dir)
  if not ok then
    error(err, 0)
  end
  return out
end

-- The LaTeX of each part, and of the whole (for diffs), written in `dir`: { [name] = path }, and
-- `all`. A manuscript of several parts is first built whole (so that each part's references to
-- the others get their numbers: knitrmini's label snapshot, or the whole's .aux), unless its last
-- build is newer than its sources; then knitted part by part.
function M.parts(project, dir)
  local out = {}
  local several = #project.parts > 1
  local ok, err = pcall(function()
    out.all = vim.fs.joinpath(dir, "all.tex")
    -- (the labels of the whole, for the numbers of each part's references to the others)
    local snapshot = require("manuscript.labels").snapshot(project)
    if several and not M.fresh(project, snapshot) then
      job.range(0, 60)
      require("manuscript.build").make(project, { label = "building the whole (for the numbers of references)" })
    end
    local fresh = several and M.fresh(project, snapshot)
    local how = knitter(project)
    if how == "knitrmini" or how == "knit.jl" or how == "knitr" then
      job.range(60, 80)
      job.say("knitting", 0)
      knit(project, "all", nil, vim.fs.joinpath(project.dir, PREFIX .. "all.tex"), false)
      if fresh then
        assert(vim.uv.fs_copyfile(snapshot, vim.fs.joinpath(project.dir, PREFIX .. "all-labels.aux")))
      end
      assert(vim.uv.fs_copyfile(vim.fs.joinpath(project.dir, PREFIX .. "all.tex"), out.all))
      flatten_file(project, out.all)
    else
      job.range(60, 80)
      job.say(project.kind == "tex" and "reading" or "rendering", 0)
      latex(project, "all", nil, out.all)
    end
    for k, part in ipairs(several and project.parts or {}) do
      job.say(("%s %s (%d/%d)"):format(project.kind == "tex" and "reading" or knitter(project) == "rmarkdown" and "rendering" or "knitting",
        part.name, k, #project.parts), math.floor(k / (#project.parts + 1) * 100))
      out[part.name] = vim.fs.joinpath(dir, part.name .. ".tex")
      latex(project, part.name, part.file, out[part.name])
    end
    if not several then
      out[project.parts[1].name] = out.all
    end
  end)
  M.clean(project.dir)
  if not ok then
    error(err, 0)
  end
  return out
end

return M
