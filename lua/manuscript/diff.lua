-- :Manuscript diff [part] [old] [new] [oldkey=newkey ...]: a PDF with the changes between two versions of
-- the manuscript, marked as tracked changes (latexdiff), as make_diff.sh did. A version is
--   (none), @          the last export (what you sent): its LaTeX, kept when exported
--   @2, @2026-10-23    an export, by its place (1 is the last) or its folder's name
--   HEAD, c2ffc81, v1  a git revision: the manuscript's files as they were then
--   path               a .tex file (as it is), or an .Rnw/.tex root or its folder (knitted)
--   .                  the manuscript now (the default new one)
-- A part's name among them (main, appendix1...) compares only that part.
-- Citation keys renamed since (the same DOI or title in the old and new .bib) are renamed in the
-- old version, so that they don't show as changes; oldkey=newkey arguments add to them.
local job = require("manuscript.job")
local project_ = require("manuscript.project")
local snapshot = require("manuscript.snapshot")
local bib = require("manuscript.bib")
local knit = require("manuscript.knit")
local M = {}

local function read(path)
  return project_.read(path) or job.fail("can't read " .. path)
end

local function write(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

-- Moves the files whose names start with `prefix` from one folder to another.
local function move(from, to, prefix)
  vim.fn.mkdir(to, "p")
  for file in vim.fs.dir(from) do
    if vim.startswith(file, prefix) then
      local a, b = vim.fs.joinpath(from, file), vim.fs.joinpath(to, file)
      if not os.rename(a, b) then -- (another file system)
        vim.uv.fs_copyfile(a, b)
        os.remove(a)
      end
    end
  end
end

local opened = {} -- (the PDFs opened: once, as the viewer reloads them)

local function git(project, args)
  local r = job.run(vim.list_extend({ "git", "-C", project.dir }, args))
  return r.code == 0 and r.stdout or nil
end

-- A version: { label, tex (its LaTeX: whole, or only `part`'s), bibs (the text of its .bib files) }.
function M.version(project, spec, cache, as, part)
  spec = spec or "@"
  local out = vim.fs.joinpath(cache, as .. ".tex")
  if spec == "." then
    local tex = part and knit.one(project, part.file, out) or knit.whole(project, out)
    local text = ""
    for _, path in ipairs(project.bibs) do
      text = text .. (project_.read(path) or "") .. "\n"
    end
    return { label = "now", tex = tex, bibs = text }
  end
  local n = spec:match("^@(%d*)$")
  if n or spec:match("^@.") then -- an export
    local list = snapshot.list(project)
    local found = n and list[tonumber(n ~= "" and n or "1")]
    if not n then
      found = vim.iter(list):find(function(s) return vim.startswith(s.name, spec:sub(2)) end)
    end
    if not found then
      job.fail(#list == 0 and "no export yet (:Manuscript export): give a version to compare with, as HEAD or a commit"
        or "no export " .. spec .. " (:Manuscript versions lists them)")
    end
    local bibs = ""
    local sources = vim.fs.joinpath(found.dir, ".manuscript", "sources")
    for _, path in ipairs(project.bibs) do -- (its .bib: copied if it wasn't committed, else from its commit)
      local rel = path:sub(#project.dir + 2)
      bibs = bibs .. (project_.read(vim.fs.joinpath(sources, rel))
        or found.manifest.commit and git(project, { "show", found.manifest.commit .. ":./" .. rel }) or "") .. "\n"
    end
    local tex = snapshot.tex(found, part and part.name)
    if not vim.uv.fs_stat(tex) then
      job.fail(("the export %s has no %s (exported before it was a part?)"):format(found.name, vim.fs.basename(tex)))
    end
    return { label = found.name, tex = tex, bibs = bibs }
  end
  local path = vim.fs.normalize(vim.fn.fnamemodify(spec, ":p"))
  if vim.uv.fs_stat(path) then -- a file or folder
    if path:match("%.tex$") and not vim.uv.fs_stat((path:gsub("%.tex$", ".Rnw"))) then
      return { label = vim.fs.basename(path):gsub("%.tex$", ""), tex = path, bibs = "" }
    end
    local other = project_.find(path)
    local text = ""
    for _, p in ipairs(other.bibs) do
      text = text .. (project_.read(p) or "") .. "\n"
    end
    local same = part and vim.iter(other.parts):find(function(p) return p.name == part.name end)
    if part and not same then
      job.fail(("%s has no part %s"):format(vim.fs.basename(other.root), part.name))
    end
    return { label = vim.fs.basename(other.dir), tex = same and knit.one(other, same.file, out) or knit.whole(other, out), bibs = text }
  end
  -- a git revision: the root, its parts and .bib files as they were, beside the root (as
  -- _manuscript-old-*), knitted there with today's data and code, as make_diff.sh did
  if not project.git then
    job.fail(spec .. " is neither an export, a file nor a folder (and the manuscript isn't in git)")
  end
  local commit = git(project, { "rev-parse", "--verify", "--quiet", spec .. "^{commit}" })
  if not commit then
    job.fail(spec .. " isn't an export, a file, a folder or a git revision")
  end
  commit = vim.trim(commit)
  local function old(file) -- (the file's text at the revision, or nil)
    return git(project, { "show", commit .. ":./" .. file:sub(#project.dir + 2) })
  end
  local root = old(project.root) or job.fail(vim.fs.basename(project.root) .. " didn't exist at " .. spec)
  local copies = {}
  for _, p in ipairs(project.parts) do
    if p.file ~= project.root then
      local name = vim.fs.basename(p.file)
      local text = old(p.file)
      if text then
        copies[#copies + 1] = "_manuscript-old-" .. name
        write(vim.fs.joinpath(project.dir, copies[#copies]), text)
        root = root:gsub("child%s*=%s*(['\"])" .. vim.pesc(name) .. "%1", "child=%1_manuscript-old-" .. name .. "%1")
          :gsub("\\input{" .. vim.pesc(name) .. "}", "\\input{_manuscript-old-" .. name .. "}")
      end
    end
  end
  local old_part = part and vim.fs.joinpath(project.dir, "_manuscript-old-" .. vim.fs.basename(part.file))
  if part and not vim.tbl_contains(copies, vim.fs.basename(old_part)) then
    knit.clean(project.dir)
    job.fail(("%s didn't exist at %s"):format(vim.fs.basename(part.file), spec))
  end
  local ok, tex
  if part then
    ok, tex = pcall(knit.one, project, old_part, out, root)
  else
    ok, tex = pcall(knit.whole, project, out, root)
  end
  knit.clean(project.dir)
  if not ok then
    error(tex, 0)
  end
  local bibs = ""
  for _, path in ipairs(project.bibs) do
    bibs = bibs .. (old(path) or "") .. "\n"
  end
  local label = vim.trim(git(project, { "rev-parse", "--short", commit }) or spec)
  return { label = spec:match("^[%w._-]+$") and spec ~= label and (spec .. "-" .. label) or label, tex = tex, bibs = bibs }
end

-- Citation keys as one list without spaces, and the old ones renamed (\parencite{a, b} -> {a,b}).
function M.citations(text, renames)
  local out, pos = {}, 1
  while true do
    local s, e = text:find("\\%a*cite%a*%*?", pos)
    if not s then
      out[#out + 1] = text:sub(pos)
      return table.concat(out)
    end
    local j = e + 1
    while true do -- (its options: [pre][post])
      local _, stop = text:find("^%s*%b[]", j)
      if not stop then
        break
      end
      j = stop + 1
    end
    local open, close = text:find("^%s*%b{}", j)
    if open then
      local list = {}
      for key in text:sub(open, close):match("{(.*)}$"):gmatch("[^,]+") do
        key = vim.trim(key)
        list[#list + 1] = renames[key] or key
      end
      out[#out + 1] = text:sub(pos, j - 1) .. "{" .. table.concat(list, ",") .. "}"
      pos = close + 1
    else
      out[#out + 1] = text:sub(pos, e)
      pos = e + 1
    end
  end
end

-- :Manuscript diff; on_done(ok) when it ends.
function M.run(args, on_done)
  job.task(function()
    local project = project_.find()
    job.need("latexdiff", "for the tracked-changes PDF")
    job.need("latexmk", "for the tracked-changes PDF")
    local renames, specs, part = {}, {}, nil
    for _, arg in ipairs(args) do
      local from, to = arg:match("^([^=]+)=(.+)$")
      local named = #project.parts > 1 and vim.iter(project.parts):find(function(p) return p.name == arg end)
      if from then
        renames[from] = to
      elseif named then -- (a part: only it; a git branch of that name is heads/<name>)
        part = named
      else
        specs[#specs + 1] = arg
      end
    end
    job.title(part and "diff " .. part.name or "diff")
    local cache = require("manuscript.export").cache(project, "diff")
    local labels = vim.fs.joinpath(project.dir, vim.fs.basename(project.root):gsub("%.[^.]+$", "") .. "-labels.aux")
    if part and project.rnw and not vim.uv.fs_stat(labels) then -- (as a build: the numbers of its references)
      local whole = vim.fs.basename(project.root):gsub("%.[^.]+$", "")
      require("manuscript.build").make(project, whole, nil, "the whole first (for the numbers of references)")
    end
    job.say("(1/4) preparing the old version: " .. (specs[1] or "the last export"), 0)
    local old = M.version(project, specs[1], cache, "old", part)
    job.say("(2/4) preparing the new version: " .. (specs[2] or "now"), 25)
    local new = M.version(project, specs[2] or ".", cache, "new", part)
    renames = vim.tbl_extend("keep", renames, bib.renames(bib.parse(old.bibs), bib.parse(new.bibs)))
    local a, b = vim.fs.joinpath(cache, "a.tex"), vim.fs.joinpath(cache, "b.tex")
    write(a, M.citations(read(old.tex), renames))
    write(b, M.citations(read(new.tex), {}))
    job.say(("(3/4) comparing %s and %s"):format(old.label, new.label), 50)
    local r = job.run(vim.list_extend(vim.list_extend({ "latexdiff" }, project.options.latexdiff), { "a.tex", "b.tex" }), { cwd = cache })
    if r.code ~= 0 then
      job.fail("latexdiff failed:\n" .. job.tail(r))
    end
    local diff = r.stdout
    -- ulem stops hyphenation: lua-ul instead, when installed; and some room to stretch lines
    if job.run({ "kpsewhich", "lua-ul.sty" }).code == 0 then
      diff = diff:gsub("\\uwave{#1}", "\\underLine{#1}", 1):gsub("\\sout{#1}", "\\strikeThrough{#1}", 1)
        :gsub("(\\RequirePackage%[normalem%]{ulem}[^\n]*)", "%1\n\\RequirePackage{lua-ul}", 1)
    end
    diff = diff:gsub("(\n\\begin{document}[^\n]*\n)", "%1\\setlength{\\emergencystretch}{3em}\n", 1)
    local name = "_manuscript-diff" -- (built where the root is: its pictures and .bib are found)
    local folder = vim.fs.joinpath(project.dir, "diff")
    vim.fn.mkdir(folder, "p")
    if not vim.uv.fs_stat(vim.fs.joinpath(folder, ".gitignore")) then
      write(vim.fs.joinpath(folder, ".gitignore"), "*\n")
    end
    local title = ((part and part.name .. "-" or "") .. old.label .. "-vs-" .. new.label):gsub("[^%w._-]", "_")
    local out = vim.fs.joinpath(folder, title .. ".pdf")
    -- (the LaTeX files of this diff's last PDF, kept in the cache: latexmk reruns only what changed)
    local kept = vim.fs.joinpath(cache, "latex", title)
    move(kept, project.dir, name .. ".")
    local pdf = vim.fs.joinpath(project.dir, name .. ".pdf")
    local log = vim.fs.joinpath(project.dir, name .. ".log")
    local function changed(file, stat) -- (since `stat`, of before latexmk)
      local now = vim.uv.fs_stat(file)
      return now and (not stat or now.mtime.sec ~= stat.mtime.sec or now.mtime.nsec ~= stat.mtime.nsec)
    end
    local before, log_before = vim.uv.fs_stat(pdf), vim.uv.fs_stat(log) -- (the last one's)
    if project_.read(vim.fs.joinpath(project.dir, name .. ".tex")) ~= diff then -- (as kept, if the same)
      write(vim.fs.joinpath(project.dir, name .. ".tex"), diff)
    end
    write(vim.fs.joinpath(cache, "diff.tex"), diff) -- (a copy, to look at if the PDF fails)
    job.say("(4/4) building the PDF", 75)
    local built = job.run({ "latexmk", require("manuscript").latexmk_flag(project.options.latex), "-interaction=nonstopmode", name .. ".tex" }, { cwd = project.dir })
    -- (made: without errors; or a new PDF anyway, with LaTeX errors that didn't stop it; or no LaTeX
    -- run, the last PDF being this one, with the errors it had then)
    local made = vim.uv.fs_stat(pdf) and (built.code == 0 or changed(pdf, before) or log_before and not changed(log, log_before))
    if not made or not vim.uv.fs_copyfile(pdf, out) then
      log = project_.read(log) or ""
      knit.clean(project.dir) -- (and what was kept: from scratch next time)
      job.fail("latexmk couldn't build the PDF:\n" .. (log:match("\n(! .-)\n\n") or job.tail(built)))
    end
    move(project.dir, kept, name .. ".")
    knit.clean(project.dir)
    job.say(vim.fn.fnamemodify(out, ":~:.") .. " ready")
    if not opened[out] then
      opened[out] = true
      vim.schedule(function() vim.ui.open(out) end)
    end
  end, on_done, "diff")
end

return M
