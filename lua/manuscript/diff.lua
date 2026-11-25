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
    if not n then -- (its name; else the last whose name starts so: @geb)
      found = vim.iter(list):find(function(s) return s.name == spec:sub(2) end)
        or vim.iter(list):find(function(s) return vim.startswith(s.name, spec:sub(2)) end)
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
  -- a git revision: the manuscript's files as they were (the root, and what it included then:
  -- child chunks, \input, \include, recursively), beside the root (as _manuscript-old-*, their
  -- references to each other rewritten), knitted there with today's data and code, as
  -- make_diff.sh did
  if not project.git then
    job.fail(spec .. " is neither an export, a file nor a folder (and the manuscript isn't in git)")
  end
  local commit = git(project, { "rev-parse", "--verify", "--quiet", spec .. "^{commit}" })
  if not commit then
    job.fail(spec .. " isn't an export, a file, a folder or a git revision")
  end
  commit = vim.trim(commit)
  local function old(rel) -- (a file's text at the revision, or nil; rel: in the root's folder)
    return git(project, { "show", commit .. ":./" .. rel })
  end
  local root_rel = vim.fs.basename(project.root)
  local texts = { [root_rel] = old(root_rel) or job.fail(root_rel .. " didn't exist at " .. spec) }
  local copies = {} -- [rel] = its copy's name
  local function rel_of(name, how) -- (the file an inclusion names, in the root's folder; or nil)
    local path = vim.fs.normalize(vim.fs.joinpath(project.dir, name))
    if how ~= "child" and not path:match("%.%w+$") then
      path = path .. ".tex"
    end
    return vim.startswith(path, project.dir .. "/") and path:sub(#project.dir + 2) or nil
  end
  local queue = { root_rel }
  while #queue > 0 do
    local rel = table.remove(queue, 1)
    for _, inc in ipairs(project_.includes(texts[rel], project_.kind(rel) or "tex")) do
      local file = rel_of(inc.name, inc.how)
      if file and not texts[file] and project_.kind(file) then
        local text = old(file)
        if text then
          texts[file], copies[file] = text, "_manuscript-old-" .. file:gsub("/", "__")
          queue[#queue + 1] = file
        end
      end
    end
  end
  local function rewrite(text) -- (references to files copied: to their copies)
    text = text:gsub("(child%s*=%s*)(['\"])([^'\"]+)%2", function(pre, q, name)
      local copy = copies[rel_of(name, "child") or ""]
      return copy and (pre .. q .. copy .. q) or nil
    end)
    return (text:gsub("\\(%a+)(%s*){([^}]+)}", function(how, space, name)
      local copy = (how == "input" or how == "include") and copies[rel_of(vim.trim(name), how) or ""]
      return copy and ("\\" .. how .. space .. "{" .. (how == "include" and copy:gsub("%.tex$", "") or copy) .. "}") or nil
    end))
  end
  for rel, copy in pairs(copies) do
    write(vim.fs.joinpath(project.dir, copy), rewrite(texts[rel]))
  end
  local root = rewrite(texts[root_rel])
  local old_part = part and (part.file == project.root and project.root
    or copies[part.file:sub(#project.dir + 2)] and vim.fs.joinpath(project.dir, copies[part.file:sub(#project.dir + 2)]))
  if part and not old_part then
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
    bibs = bibs .. (vim.startswith(path, project.dir .. "/") and old(path:sub(#project.dir + 2)) or "") .. "\n"
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
    local renames, specs, part, variant = {}, {}, nil, nil
    local variants = require("manuscript.variants").all(project)
    for _, arg in ipairs(args) do
      local from, to = arg:match("^([^=]+)=(.+)$")
      local named = #project.parts > 1 and vim.iter(project.parts):find(function(p) return p.name == arg end)
      if from then
        renames[from] = to
      elseif named then -- (a part: only it; a git branch of that name is heads/<name>)
        part = named
      elseif variants[arg] then -- (a variant: its switches; a git branch of that name is heads/<name>)
        variant = arg
      else
        specs[#specs + 1] = arg
      end
    end
    job.title(part and "diff " .. part.name or "diff")
    require("manuscript.figures").update(project)
    local cache = require("manuscript.export").cache(project, "diff")
    if part and not require("manuscript.build").has_labels(project, part) then -- (as a build: the numbers of its references)
      local ok, err = pcall(require("manuscript.build").make, project, { label = "the whole first (for the numbers of references)" })
      knit.clean(project.dir)
      if not ok then
        error(err, 0)
      end
    end
    job.say("(1/4) preparing the old version: " .. (specs[1] or "the last export"), 0)
    local old = M.version(project, specs[1], cache, "old", part)
    job.say("(2/4) preparing the new version: " .. (specs[2] or "now"), 25)
    local new = M.version(project, specs[2] or ".", cache, "new", part)
    renames = vim.tbl_extend("keep", renames, bib.renames(bib.parse(old.bibs), bib.parse(new.bibs)))
    local a, b = vim.fs.joinpath(cache, "a.tex"), vim.fs.joinpath(cache, "b.tex")
    -- (flattened: an export made before they were kept so may \input{} files)
    write(a, M.citations(project_.flatten(read(old.tex), project.dir), renames))
    write(b, M.citations(project_.flatten(read(new.tex), project.dir), {}))
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
    local folder = vim.fs.joinpath(project.dir, "diff")
    vim.fn.mkdir(folder, "p")
    if not vim.uv.fs_stat(vim.fs.joinpath(folder, ".gitignore")) then
      write(vim.fs.joinpath(folder, ".gitignore"), "*\n")
    end
    local title = ((part and part.name .. "-" or "") .. old.label .. "-vs-" .. new.label .. (variant and "-" .. variant or ""))
      :gsub("[^%w._-]", "_")
    local out = vim.fs.joinpath(folder, title .. ".pdf")
    -- (built in .build/diff/, run where the root is: its pictures and .bib are found; its LaTeX
    -- files kept, so that latexmk reruns only what changed)
    local built_in = require("manuscript.build").dir(project, "diff")
    local tex = vim.fs.joinpath(built_in, title .. ".tex")
    local pdf = vim.fs.joinpath(built_in, title .. ".pdf")
    local log = vim.fs.joinpath(built_in, title .. ".log")
    local function changed(file, stat) -- (since `stat`, of before latexmk)
      local now = vim.uv.fs_stat(file)
      return now and (not stat or now.mtime.sec ~= stat.mtime.sec or now.mtime.nsec ~= stat.mtime.nsec)
    end
    local before, log_before = vim.uv.fs_stat(pdf), vim.uv.fs_stat(log) -- (the last one's)
    if project_.read(tex) ~= diff then -- (as kept, if the same)
      write(tex, diff)
    end
    job.say("(4/4) building the PDF", 75)
    local built = job.run({ "latexmk", require("manuscript").latexmk_flag(project.options.latex), "-interaction=nonstopmode",
      "-outdir=.build/diff", "-jobname=" .. title, "-usepretex=" .. require("manuscript.variants").pretex(project, variant),
      ".build/diff/" .. title .. ".tex" }, { cwd = project.dir })
    -- (made: without errors; or a new PDF anyway, with LaTeX errors that didn't stop it; or no LaTeX
    -- run, the last PDF being this one, with the errors it had then)
    local made = vim.uv.fs_stat(pdf) and (built.code == 0 or changed(pdf, before) or log_before and not changed(log, log_before))
    if not made or not vim.uv.fs_copyfile(pdf, out) then
      log = project_.read(log) or ""
      for file in vim.fs.dir(built_in) do -- (from scratch next time)
        if file:sub(1, #title + 1) == title .. "." then
          os.remove(vim.fs.joinpath(built_in, file))
        end
      end
      job.fail("latexmk couldn't build the PDF:\n" .. (log:match("\n(! .-)\n\n") or job.tail(built)))
    end
    knit.clean(project.dir)
    job.say(vim.fn.fnamemodify(out, ":~:.") .. " ready")
    if not opened[out] then
      opened[out] = true
      vim.schedule(function() vim.ui.open(out) end)
    end
  end, on_done, "diff")
end

return M
