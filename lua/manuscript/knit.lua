-- The LaTeX of a manuscript: an .Rnw root is knitted (with knitrmini, or knitr), one part at a time
-- as you would by hand: a copy of the root with only that part's child chunk evaluated. A .tex
-- root is its own LaTeX.
--
-- Copies of the root are written beside it (_manuscript-<part>.Rnw: knitting must run where the
-- root is, for its relative paths; a name starting with "." can't be compiled, as TeX doesn't write
-- such files), and removed with all they produced.
local job = require("manuscript.job")
local project_ = require("manuscript.project")
local M = {}

local PREFIX = "_manuscript-"

-- The root with only `part`'s child chunk evaluated (all of them when part is nil).
function M.root_for(text, part_file, dir)
  return (text:gsub("[^\n]+", function(line)
    local options = line:match("^%s*<<(.*)>>=%s*$")
    local child = options and options:match("child%s*=%s*['\"]([^'\"]+)['\"]")
    if not child then
      return line
    end
    local on = not part_file or vim.fs.normalize(vim.fs.joinpath(dir, child)) == part_file
    local rest = options:gsub(",?%s*eval%s*=%s*[^,]+", ""):gsub("^%s*,%s*", "")
    return line:match("^%s*") .. "<<" .. rest .. ", eval=" .. (on and "TRUE" or "FALSE") .. ">>="
  end))
end

local engine -- (knitrmini or knitr: asked once)
local function knitter(project)
  if project.options.knit then
    return project.options.knit
  end
  if not engine then
    local r = job.run({ "Rscript", "-e", 'cat(requireNamespace("knitrmini", quietly = TRUE))' })
    engine = vim.trim(r.stdout or "") == "TRUE" and "knitrmini" or "knitr"
  end
  return engine
end

-- Removes what the copies of the root produced.
function M.clean(dir)
  for name in vim.fs.dir(dir) do
    if vim.startswith(name, PREFIX) then
      os.remove(vim.fs.joinpath(dir, name))
    end
  end
end

-- Knits `name`'s copy of the root (only `part_file`, or all if nil) into `out`; compile: also
-- builds the PDF (in the root's folder, under the copy's name), for the labels of the whole.
local function knit(project, name, part_file, out, compile, text)
  text = text or project_.read(project.root)
  local copy = PREFIX .. name .. ".Rnw"
  local f = assert(io.open(vim.fs.joinpath(project.dir, copy), "w"))
  f:write(M.root_for(text, part_file, project.dir))
  f:close()
  -- (the labels of the whole, for references to other parts: an export's, or a build's)
  local snapshot = vim.fs.joinpath(project.dir, PREFIX .. "all-labels.aux")
  if not vim.uv.fs_stat(snapshot) then
    snapshot = vim.fs.joinpath(project.dir, vim.fs.basename(project.root):gsub("%.[^.]+$", "") .. "-labels.aux")
  end
  if name ~= "all" and vim.uv.fs_stat(snapshot) then
    vim.uv.fs_copyfile(snapshot, vim.fs.joinpath(project.dir, PREFIX .. name .. "-labels.aux"))
  end
  local expr
  if knitter(project) == "knitrmini" then
    expr = ("knitrmini::knit(%q, output = %q, compile = %s, quiet = TRUE)"):format(copy, out, compile and "TRUE" or "FALSE")
  else
    expr = ("knitr::knit(%q, output = %q, quiet = TRUE)"):format(copy, out)
  end
  local r = job.run({ "Rscript", "-e", expr }, { cwd = project.dir })
  if r.code ~= 0 or not vim.uv.fs_stat(out) then
    job.fail(("knitting %s failed:\n%s"):format(name, job.tail(r)))
  end
  return r
end

-- Whether a file is newer than all the sources of the manuscript (its root, parts and .bib).
function M.fresh(project, file)
  local st = vim.uv.fs_stat(file)
  if not st then
    return false
  end
  local files = vim.list_extend({ project.root }, project.bibs)
  for _, part in ipairs(project.parts) do
    files[#files + 1] = part.file
  end
  for _, f in ipairs(files) do
    local s = vim.uv.fs_stat(f)
    if s and (s.mtime.sec > st.mtime.sec or s.mtime.sec == st.mtime.sec and s.mtime.nsec > st.mtime.nsec) then
      return false
    end
  end
  return true
end

-- The LaTeX of the whole manuscript into `out` (no PDF). text: the root's text to knit instead of
-- the root's (an old version's: see diff.lua).
function M.whole(project, out, text)
  if not project.rnw then
    local f = assert(io.open(out, "wb"))
    f:write(text or project_.read(project.root))
    f:close()
    return out
  end
  job.need("Rscript", "to knit .Rnw files")
  local ok, err = pcall(knit, project, "all", nil, out, false, text)
  M.clean(project.dir)
  if not ok then
    error(err, 0)
  end
  return out
end

-- The LaTeX of one part (`part_file`: its child's file, as the root names it) into `out` (no
-- PDF). text: the root's text to knit instead of the root's (an old version's).
function M.one(project, part_file, out, text)
  if not project.rnw then
    return M.whole(project, out, text)
  end
  job.need("Rscript", "to knit .Rnw files")
  local ok, err = pcall(knit, project, "part", part_file, out, false, text)
  M.clean(project.dir)
  if not ok then
    error(err, 0)
  end
  return out
end

-- The LaTeX of each part, and of the whole (for diffs), written in `dir`: { [name] = path }, and
-- `all`. An .Rnw root with several parts is first built whole (so that each part's references to
-- the others get their numbers), then knitted part by part.
function M.parts(project, dir)
  local out = {}
  if not project.rnw then
    local tex = vim.fs.joinpath(dir, project.parts[1].name .. ".tex")
    assert(vim.uv.fs_copyfile(project.root, tex))
    out[project.parts[1].name], out.all = tex, tex
    return out
  end
  job.need("Rscript", "to knit .Rnw files")
  local ok, err = pcall(function()
    local several = #project.parts > 1
    out.all = vim.fs.joinpath(dir, "all.tex")
    -- (the labels of the whole: a :Manuscript build's, if newer than the sources; else built now)
    local snapshot = vim.fs.joinpath(project.dir, vim.fs.basename(project.root):gsub("%.[^.]+$", "") .. "-labels.aux")
    local fresh = several and M.fresh(project, snapshot)
    if several and not fresh and knitter(project) == "knitrmini" then -- (as :Manuscript build all does)
      job.range(0, 60)
      require("manuscript.build").make(project, vim.fs.basename(project.root):gsub("%.[^.]+$", ""), nil,
        "building the whole (for the numbers of references)")
      fresh = M.fresh(project, snapshot)
    end
    job.range(60, 80)
    job.say("knitting", 0)
    knit(project, "all", nil, vim.fs.joinpath(project.dir, PREFIX .. "all.tex"), false)
    if fresh then
      assert(vim.uv.fs_copyfile(snapshot, vim.fs.joinpath(project.dir, PREFIX .. "all-labels.aux")))
    end
    assert(vim.uv.fs_copyfile(vim.fs.joinpath(project.dir, PREFIX .. "all.tex"), out.all))
    for k, part in ipairs(several and project.parts or {}) do
      job.say(("knitting %s (%d/%d)"):format(part.name, k, #project.parts), math.floor(k / (#project.parts + 1) * 100))
      out[part.name] = vim.fs.joinpath(dir, part.name .. ".tex")
      knit(project, part.name, part.file, out[part.name], false)
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
