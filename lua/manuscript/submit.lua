-- :Manuscript submit [variant] [anonymous|named]: what a journal asks for, in submission/<variant>-<date>/
--
--   manuscript.pdf             the main text, built with the variant's switches
--   Appendix_S1.pdf, ...       each part after it (or none: appendices = "inline")
--   title_page.pdf, ...        title_page.tex, cover_letter.tex, response.tex beside the root, built
--   latex/                     what compiles manuscript.pdf, and nothing else:
--     manuscript.tex             knitted, flattened (\input{}s inlined), comments out, the switches
--                                resolved in the text (an anonymous source has no authors at all)
--     figures/                   the pictures it reads, its paths rewritten
--     references.bib             only the entries it cites; manuscript.bbl
--     *.sty, *.cls...            the local packages and classes it reads
--   <folder>-latex.zip         latex/, to upload
--
-- latex/ is compiled on its own, elsewhere, before it is kept: a bundle that doesn't build fails
-- here, not at the journal. An anonymous one is searched for the authors (their names and emails,
-- from the author block of the named version, git's, the option `identity`), and its PDFs have no
-- author or file paths in their metadata. A submission is recorded as an export is (the LaTeX it
-- was made from): :Manuscript diff @geb compares with the last one to geb.
--
-- A variant's `submit` table changes these (see M.defaults).
local job = require("manuscript.job")
local project_ = require("manuscript.project")
local latex = require("manuscript.latex")
local bib = require("manuscript.bib")
local M = {}

M.defaults = {
  appendices = "separate", -- each part after the main text in its own PDF; "inline": one document
  appendix_name = "Appendix_S%d", -- their PDFs' names
  figures = "names", -- in latex/figures/ under their names; "numbered": fig1.pdf, fig2.png...
  comments = false, -- true: comments stay in the source
  extras = { "title_page", "cover_letter", "response" }, -- .tex files beside the root, built into PDFs
  changes = true, -- a resubmission: the tracked changes since the last one with this variant
}

local IMAGE = { pdf = true, png = true, jpg = true, jpeg = true, eps = true, ps = true, mps = true, svg = true,
  tif = true, tiff = true, gif = true, bmp = true, jbig2 = true, jb2 = true }
local SUPPORT = { sty = true, cls = true, clo = true, bst = true, bbx = true, cbx = true, lbx = true, dbx = true,
  def = true, cfg = true, ldf = true, fd = true }

local function ext(path)
  return (path:match("%.([%w]+)$") or ""):lower()
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

-- The files a build read (its .fls), but TeX's own (those in your TEXMFHOME, `home`, are yours:
-- a journal doesn't have them): absolute paths, in order.
function M.inputs(fls, dir, home)
  local out, seen, pwd = {}, {}, dir
  for line in (project_.read(fls) or ""):gmatch("[^\n]+") do
    pwd = line:match("^PWD (.+)$") or pwd
    local input = line:match("^INPUT (.+)$")
    if input then
      local path = input:sub(1, 1) == "/" and input or vim.fs.normalize(vim.fs.joinpath(pwd, input))
      local mine = home and home ~= "" and path:sub(1, #home + 1) == home .. "/"
      if not seen[path] and (mine or not (path:match("/texmf") or path:match("/texlive/") or path:match("^/usr/")
        or path:match("^/etc/") or path:match("^/var/") or path:match("/%.texlive"))) then
        seen[path], out[#out + 1] = true, path
      end
    end
  end
  return out
end

-- Each \cmd[...]{arg} of a text: { { s, e (of the whole), arg, arg_s, arg_e } } (its optional argument
-- and a star are skipped).
local function commands(text, cmd)
  local out, pos = {}, 1
  while true do
    local a, b = text:find("\\" .. cmd .. "%f[^%a]", pos)
    if not a then
      return out
    end
    local i = b + 1
    i = text:find("^%*", i) and i + 1 or i
    i = text:match("^%s*()", i)
    if text:sub(i, i) == "[" then
      local _, close = text:find("^%b[]", i)
      i = close and text:match("^%s*()", close + 1) or i
    end
    local _, close = text:find("^%b{}", i)
    if close then
      out[#out + 1] = { s = a, e = close, arg = text:sub(i + 1, close - 1), arg_s = i + 1, arg_e = close - 1 }
      pos = close + 1
    else
      pos = b + 1
    end
  end
end

-- The figures of `tex` (its \includegraphics{}), among the files the build read: their paths
-- rewritten to figures/<name>, and { [file] = name } to copy. numbered: fig1.pdf... (a path made
-- in a macro, growth_#1, keeps its files' names: they are all copied).
function M.figures(tex, read, dir, numbered)
  local images = {}
  for _, path in ipairs(read) do
    if IMAGE[ext(path)] then
      images[#images + 1] = path
      images[path] = true
    end
  end
  local roots = { "" }
  for _, g in ipairs(commands(tex, "graphicspath")) do
    for p in g.arg:gmatch("{([^}]*)}") do
      roots[#roots + 1] = p
    end
  end
  local copies, taken, n = {}, {}, 0
  local function name_for(path, keep)
    if copies[path] then
      return copies[path]
    end
    local name = vim.fs.basename(path)
    if numbered and not keep then
      n = n + 1
      name = ("fig%d.%s"):format(n, ext(path))
    end
    local k = 1
    while taken[name] do -- (two pictures of that name, in different folders)
      k = k + 1
      name = vim.fs.basename(path):gsub("(%.[^.]+)$", "-" .. k .. "%1")
    end
    taken[name], copies[path] = true, name
    return name
  end
  local function resolve(p)
    for _, root in ipairs(roots) do
      for _, e in ipairs({ "", ".pdf", ".png", ".jpg", ".jpeg", ".eps", ".mps", ".PDF", ".PNG", ".JPG" }) do
        local full = (p .. e):sub(1, 1) == "/" and p .. e or vim.fs.normalize(vim.fs.joinpath(dir, root, p .. e))
        if images[full] then
          return full
        end
      end
    end
  end
  local out, last = {}, 1
  for _, c in ipairs(commands(tex, "includegraphics")) do
    local p = vim.trim(c.arg)
    local new
    if p:find("#%d") then -- (in a macro: every file it can be)
      local pattern = "^" .. vim.pesc(p):gsub("#%d", ".-") .. "$"
      for _, path in ipairs(images) do
        local rel = path:sub(1, #dir + 1) == dir .. "/" and path:sub(#dir + 2) or path
        if path:match(pattern) or rel:match(pattern) or vim.fs.basename(path):match("^" .. vim.pesc(vim.fs.basename(p)):gsub("#%d", ".-") .. "$") then
          name_for(path, true)
        end
      end
      new = "figures/" .. vim.fs.basename(p)
    else
      local full = resolve(p)
      new = full and "figures/" .. name_for(full)
    end
    if new then
      out[#out + 1] = tex:sub(last, c.arg_s - 1) .. new
      last = c.arg_e + 1
    end
  end
  out[#out + 1] = tex:sub(last)
  tex = table.concat(out)
  for _, g in ipairs(commands(tex, "graphicspath")) do -- (no longer needed: the paths are figures/)
    tex = tex:sub(1, g.s - 1) .. tex:sub(g.e + 1)
  end
  return tex, copies
end

-- \addbibresource{...}s (and BibTeX's \bibliography{...}) as the bundle's one references.bib.
function M.bibliography(tex)
  local first = true
  local out, last = {}, 1
  for _, c in ipairs(commands(tex, "addbibresource")) do
    out[#out + 1] = tex:sub(last, c.s - 1) .. (first and "\\addbibresource{references.bib}" or "")
    last, first = c.e + 1, false
    if tex:sub(last, last) == "\n" and not out[#out]:match("references%.bib}$") then
      last = last + 1 -- (a line of its own: gone with it)
    end
  end
  out[#out + 1] = tex:sub(last)
  tex = table.concat(out)
  return (tex:gsub("\\bibliography%s*{[^}]*}", "\\bibliography{references}"))
end

-- The source of a submission from a build's knitted LaTeX: flattened, comments out (unless
-- `comments`), the switches resolved with their values, \manuscriptvariant replaced, the switches'
-- guards gone.
function M.source(text, dir, values, variant, comments)
  text = project_.flatten(text, dir)
  if not comments then
    text = latex.strip_comments(text)
  end
  text = latex.resolve(text, values)
  text = text:gsub("\\manuscriptvariant%f[^%a]", ((variant or ""):gsub("%%", "%%%%")))
  for name in pairs(values) do
    text = text:gsub("[ \t]*\\ifcsname%s+if" .. name .. "%s*\\endcsname%s*\\else%s*\\expandafter%s*\\newif%s*\\csname%s+if"
      .. name .. "%s*\\endcsname%s*\\fi[ \t]*\n?", "")
  end
  return (text:gsub("\n[ \t]*\n[ \t]*\n[%s]*", "\n\n")) -- (where blocks went: one blank line)
end

-- Who wrote it, to search an anonymous submission for: the names and emails of the author block of
-- the named version (\author, \affil...; an .Rmd's YAML authors), git's user, and the option
-- `identity`. Names give their words of 4 letters or more too (a surname alone).
function M.identity(project, named)
  local found = {}
  local function add(s)
    s = vim.trim((s or ""):gsub("%s+", " "))
    if #s >= 4 then
      found[s] = true
    end
  end
  local function name(raw)
    raw = raw:gsub("\\%a+%s*%b{}", " "):gsub("\\%a+", " "):gsub("%$[^$]*%$", " "):gsub("[{}~\\]", " ")
    for one in (raw .. ","):gmatch("([^,;\n]+)[,;\n]") do
      for piece in (one .. " and "):gmatch("(.-)%s+and%s+") do
        add(piece)
        for word in piece:gmatch("[^%s%.]+") do
          if #word >= 4 and not word:match("^%l") then
            add(word)
          end
        end
      end
    end
  end
  for _, cmd in ipairs({ "author", "affil", "affiliation", "address", "institute", "thanks", "corresp", "email" }) do
    for _, c in ipairs(commands(named, cmd)) do
      for email in c.arg:gmatch("[%w._%%+-]+@[%w.-]+%.%a+") do
        add(email)
      end
      if cmd == "author" or cmd == "corresp" then
        name(c.arg:gsub("[%w._%%+-]+@[%w.-]+%.%a+", ""))
      else
        add((c.arg:gsub("\\%a+%s*", " "):gsub("[{}]", "")))
      end
    end
  end
  for email in named:gmatch("[%w._%%+-]+@[%w-]+%.[%w.-]*%a") do
    add(email)
  end
  if project.kind == "rmd" then
    local header = (project_.read(project.root) or ""):match("^%-%-%-%s*\n(.-)\n%-%-%-") or ""
    for value in header:gmatch("\n%s*%-?%s*name:%s*([^\n]+)") do
      name((value:gsub("^[\"']", ""):gsub("[\"']%s*$", "")))
    end
    for value in header:gmatch("email:%s*([^\n]+)") do
      add((value:gsub("[\"']", "")))
    end
  end
  if project.git then
    for _, key in ipairs({ "user.name", "user.email" }) do
      local r = job.run({ "git", "-C", project.dir, "config", key })
      if r.code == 0 then
        if key == "user.name" then
          name(vim.trim(r.stdout))
        else
          add(vim.trim(r.stdout))
        end
      end
    end
  end
  for _, s in ipairs(project.options.identity or {}) do
    add(s)
  end
  local out = vim.tbl_keys(found)
  table.sort(out)
  return out
end

-- LaTeX without the keys of its citations (\cite{lourdais2004}, \textcite[p.~2]{x,y}...: a key
-- names an author, and is no trace of who wrote it).
function M.without_keys(text)
  local out, pos = {}, 1
  while true do
    local a, b = text:find("\\%a*[cC]ite%a*%*?", pos)
    if not a then
      out[#out + 1] = text:sub(pos)
      return table.concat(out)
    end
    local i = text:match("^%s*()", b + 1)
    while text:sub(i, i) == "[" do -- (its notes)
      local _, close = text:find("^%b[]", i)
      if not close then
        break
      end
      i = text:match("^%s*()", close + 1)
    end
    local _, close = text:find("^%b{}", i)
    out[#out + 1] = text:sub(pos, b)
    if close then
      out[#out + 1] = text:sub(b + 1, i - 1) .. "{}"
      pos = close + 1
    else
      pos = b + 1
    end
  end
end

-- Where `who` shows in the files of an anonymous submission: { quickfix items, each with `cited`
-- when it is in the bibliography (references.bib, .bbl), or in a PDF's text and the bibliography
-- too: a self-citation is not a leak, and stays }.
-- Whether `line` has `w`: a word (a name) as a whole word, with its capitals (Ana, not analysis
-- nor \author); a phrase or an email, in any case.
function M.has(line, w)
  if w:find("[%s@]") then
    return line:lower():find(w:lower(), 1, true) ~= nil
  end
  local pos = 1
  while true do
    local a, b = line:find(w, pos, true)
    if not a then
      return false
    end
    local before, after = line:sub(a - 1, a - 1), line:sub(b + 1, b + 1)
    local function word(c) -- (a letter, a digit, or a byte of a UTF-8 letter: Martínez)
      return c ~= "" and (c:match("[%w_]") or c:byte() >= 128)
    end
    if not word(before) and not word(after) then
      return true
    end
    pos = a + 1
  end
end

function M.leaks(folder, who, pdfs)
  local items, in_bib = {}, {}
  local function search(text, filename, where, bib)
    local n = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      n = n + 1
      for k, w in ipairs(who) do
        if M.has(line, w) then
          in_bib[k] = in_bib[k] or bib
          items[#items + 1] = { filename = filename, lnum = filename and n or nil, who = k, cited = bib,
            text = ("%s: %q%s"):format(where, who[k], filename and "" or " — " .. vim.trim(line):sub(1, 80)), type = "W" }
        end
      end
    end
  end
  local src = vim.fs.joinpath(folder, "latex")
  for _, file in ipairs(vim.fn.globpath(src, "**/*", false, true)) do
    local e = ext(file)
    if not IMAGE[e] and vim.fn.isdirectory(file) == 0 then
      local bib_file = e == "bib" or e == "bbl"
      local text = project_.read(file) or ""
      search(bib_file and text or M.without_keys(text), file, bib_file and "in the bibliography (a self-citation?)" or "in the source", bib_file)
    end
  end
  for _, pdf in ipairs(pdfs) do
    local name = vim.fs.basename(pdf)
    local text = job.run({ "pdftotext", pdf, "-" }).stdout or ""
    search(text, nil, name .. ", its text")
    local info = (job.run({ "pdfinfo", pdf }).stdout or ""):gsub("[^\n]-:%s*", "", 1) -- (the values)
    info = ("\n" .. info):gsub("\n[%w ]+:%s*", "\n")
    search(info, nil, name .. ", its metadata")
    local raw = project_.read(pdf) or ""
    if raw:find("/home/", 1, true) or raw:find("/Users/", 1, true) then
      items[#items + 1] = { text = name .. ": a file path of this computer (/home/...) in the PDF", type = "W" }
    end
  end
  for _, item in ipairs(items) do -- (in a PDF's text, and in the bibliography: the references list)
    if item.who and not item.cited and not item.filename and in_bib[item.who] and item.text:find(", its text", 1, true) then
      item.cited, item.text = true, item.text .. " (in the bibliography too: a self-citation?)"
    end
    item.who = nil
  end
  return items
end

-- :Manuscript submit [variant] [anonymous|named]; on_done(ok).
function M.run(args, on_done)
  local after -- (a resubmission: the tracked changes since the last one, made when it's done)
  job.task(function()
    local project = project_.find()
    local variants = require("manuscript.variants")
    local build = require("manuscript.build")
    local knit = require("manuscript.knit")
    local name, force
    for _, arg in ipairs(args or {}) do
      if arg == "anonymous" or arg == "named" then
        force = arg
      elseif variants.all(project)[arg] then
        name = arg
      else
        job.fail(("%s: not a variant (the variants: %s), nor anonymous or named"):format(arg, table.concat(variants.names(project), ", ")))
      end
    end
    if force == "anonymous" and not name then
      name = "anon"
    end
    -- (the variant this submission is built with: forced anonymous or named, under a name of its own)
    project.options.variants = project.options.variants or {}
    local spec = vim.deepcopy(variants.all(project)[name] or {})
    if force then
      spec.anonymous = force == "anonymous"
      name = (name or "manuscript") .. (force == "anonymous" and name ~= "anon" and "-anonymous" or force == "named" and "-named" or "")
      project.options.variants[name] = spec
    end
    -- (and named, for the title page, the cover letter, and to know who wrote it)
    local named = name
    if spec.anonymous then
      named = (name == "anon" and "manuscript" or name or "manuscript"):gsub("%-anonymous$", "") .. "-named"
      project.options.variants[named] = vim.tbl_extend("force", vim.deepcopy(spec), { anonymous = false })
    end
    local settings = vim.tbl_extend("force", M.defaults, spec.submit or {})
    local anonymous = spec.anonymous == true
    local values = variants.values(project, name)
    job.title("submit " .. (name or ""))
    job.need("latexmk", "to build the submission")
    if project.kind == "jnw" then
      job.need("julia", "to knit " .. vim.fs.basename(project.root))
    elseif project.kind ~= "tex" then
      job.need("Rscript", "to knit " .. vim.fs.basename(project.root))
    end

    -- the folder: submission/<variant>-<date>/
    local base = vim.fs.joinpath(project.dir, "submission")
    vim.fn.mkdir(base, "p")
    if not vim.uv.fs_stat(vim.fs.joinpath(base, ".gitignore")) then
      write(vim.fs.joinpath(base, ".gitignore"), "*\n")
    end
    local stem, n = (name or "manuscript") .. "-" .. os.date("%Y-%m-%d"), 1
    while vim.uv.fs_stat(vim.fs.joinpath(base, n == 1 and stem or stem .. "-" .. n)) do
      n = n + 1
    end
    local folder = vim.fs.joinpath(base, n == 1 and stem or stem .. "-" .. n)
    local src = vim.fs.joinpath(folder, "latex")
    vim.fn.mkdir(src, "p")
    local ok, err = pcall(function()
      require("manuscript.figures").update(project)

      -- 1. the main text (or the whole), built with the variant
      local several = #project.parts > 1 and settings.appendices ~= "inline"
      local main = several and (vim.iter(project.parts):find(function(p) return p.name == "main" end) or project.parts[1]) or nil
      if main and not build.has_labels(project) then
        job.range(0, 15)
        build.make(project, { label = "the whole first (for the numbers of references)" })
      end
      job.range(15, 40)
      local target = main and main.name or project.name
      local job_name = target .. (name and "-" .. name or "")
      local made = build.make(project, { part = main, job = job_name, variant = name, label = "the main text", inside = true })
      local errors = build.in_sources(build.errors(made.log, made.tex), project)
      knit.clean(project.dir)
      if #errors > 0 then
        build.show(errors, "manuscript build: " .. job_name)
        job.fail(("the main text has LaTeX errors: %d in the quickfix list"):format(#errors))
      end
      local outdir = vim.fs.joinpath(project.dir, ".build", target)
      assert(vim.uv.fs_copyfile(vim.fs.joinpath(outdir, job_name .. ".pdf"), vim.fs.joinpath(folder, "manuscript.pdf")))
      local pdfs = { vim.fs.joinpath(folder, "manuscript.pdf") }

      -- 2. the appendices, each its own PDF
      local k = 0
      for i, part in ipairs(several and project.parts or {}) do
        if part ~= main then
          k = k + 1
          job.range(40, 55)
          job.say(("appendix %s (%d/%d)"):format(part.name, k, #project.parts - 1), math.floor(i / #project.parts * 100))
          local pj = part.name .. (name and "-" .. name or "")
          local m = build.make(project, { part = part, job = pj, variant = name, label = part.name, inside = true })
          local e = build.in_sources(build.errors(m.log, m.tex), project)
          knit.clean(project.dir)
          if #e > 0 then
            build.show(e, "manuscript build: " .. pj)
            job.fail(("%s has LaTeX errors: %d in the quickfix list"):format(part.name, #e))
          end
          local to = vim.fs.joinpath(folder, settings.appendix_name:format(k) .. ".pdf")
          assert(vim.uv.fs_copyfile(vim.fs.joinpath(project.dir, ".build", part.name, pj .. ".pdf"), to))
          pdfs[#pdfs + 1] = to
        end
      end

      -- 3. the title page, the cover letter, the response to reviewers: named
      job.range(55, 60)
      local extras = {}
      for _, extra in ipairs(settings.extras or {}) do
        local tex = vim.fs.joinpath(project.dir, extra .. ".tex")
        if vim.uv.fs_stat(tex) then
          job.say(extra)
          local dir = build.dir(project, extra)
          job.run({ "latexmk", require("manuscript").latexmk_flag(knit.engine(project)), "-interaction=nonstopmode",
            "-outdir=.build/" .. extra, "-jobname=" .. extra, "-usepretex=" .. variants.pretex(project, named),
            extra .. ".tex" }, { cwd = project.dir })
          local e = build.errors(vim.fs.joinpath(dir, extra .. ".log"), tex)
          if #e > 0 or not vim.uv.fs_stat(vim.fs.joinpath(dir, extra .. ".pdf")) then
            build.show(e, "manuscript build: " .. extra)
            job.fail(("%s.tex has LaTeX errors: %d in the quickfix list"):format(extra, #e))
          end
          assert(vim.uv.fs_copyfile(vim.fs.joinpath(dir, extra .. ".pdf"), vim.fs.joinpath(folder, extra .. ".pdf")))
          extras[#extras + 1] = extra .. ".pdf"
        end
      end

      -- 4. latex/: its source, figures, bibliography, local packages
      job.range(60, 65)
      job.say("the source")
      local knitted = project_.read(made.tex) or ""
      local text = M.source(knitted, project.dir, values, name, settings.comments)
      local home = vim.trim(job.run({ "kpsewhich", "-var-value", "TEXMFHOME" }).stdout or "")
      local read = M.inputs(vim.fs.joinpath(outdir, job_name .. ".fls"), project.dir, vim.fs.normalize(home))
      local copies
      text, copies = M.figures(text, read, project.dir, settings.figures == "numbered")
      for path, fig in pairs(copies) do
        vim.fn.mkdir(vim.fs.joinpath(src, "figures"), "p")
        assert(vim.uv.fs_copyfile(path, vim.fs.joinpath(src, "figures", fig)))
      end
      for _, path in ipairs(read) do
        if SUPPORT[ext(path)] then
          assert(vim.uv.fs_copyfile(path, vim.fs.joinpath(src, vim.fs.basename(path))))
        end
      end
      local bbl = project_.read(vim.fs.joinpath(outdir, job_name .. ".bbl"))
      local cited = bbl and bib.cited(bbl) or {}
      if #cited > 0 then
        write(vim.fs.joinpath(src, "references.bib"), bib.subset(project.bibs, cited))
        write(vim.fs.joinpath(src, "manuscript.bbl"), bbl)
        text = M.bibliography(text)
      end
      write(vim.fs.joinpath(src, "manuscript.tex"), text)

      -- 5. it compiles on its own (elsewhere), into as many pages
      job.range(65, 85)
      job.say("checking that latex/ compiles on its own")
      local check = vim.fn.tempname()
      vim.fn.mkdir(check, "p")
      job.run({ "cp", "-r", src .. "/.", check })
      job.run({ "latexmk", require("manuscript").latexmk_flag(knit.engine(project)), "-interaction=nonstopmode",
        "manuscript.tex" }, { cwd = check, env = { TEXMFHOME = check .. "/.none" } }) -- (as a journal: without your packages)
      local e = build.errors(vim.fs.joinpath(check, "manuscript.log"), vim.fs.joinpath(src, "manuscript.tex"))
      local pages = function(pdf)
        return tonumber((job.run({ "pdfinfo", pdf }).stdout or ""):match("Pages:%s*(%d+)"))
      end
      if #e > 0 or not vim.uv.fs_stat(vim.fs.joinpath(check, "manuscript.pdf")) then
        build.show(e, "manuscript submit: latex/")
        job.fail(("latex/ doesn't compile on its own (%d errors in the quickfix list; tried in %s)"):format(#e, check))
      end
      local same = pages(vim.fs.joinpath(check, "manuscript.pdf")) == pages(pdfs[1])
      vim.fn.delete(check, "rf")
      local zip = vim.fs.joinpath(folder, vim.fs.basename(folder) .. "-latex.zip")
      local r = job.run({ "zip", "-r", "-q", "-X", zip, "." }, { cwd = src })
      if r.code ~= 0 then
        job.fail("zip failed:\n" .. job.tail(r))
      end

      -- 6. anonymous: who wrote it, nowhere
      job.range(85, 88)
      local leaks = {}
      if anonymous then
        job.say("searching it for the authors")
        local who = M.source(knitted, project.dir, variants.values(project, named), name, true)
        leaks = M.leaks(folder, M.identity(project, who), pdfs)
      end

      -- 7. recorded, for diffs (:Manuscript diff @<folder>); the last one with this variant, if any,
      -- compared with it next (its own task: a diff)
      local snapshot = require("manuscript.snapshot")
      local last = vim.iter(snapshot.list(project)):find(function(x)
        return x.manifest.kind == "submission" and x.manifest.variant == name and x.dir ~= folder
      end)
      if last and settings.changes ~= false then
        -- (with the variant's switches: a manuscript's own, or anon's for an anonymity forced here)
        local known = require("manuscript").options(project.dir)
        local v = (vim.tbl_extend("force", variants.BUILTIN, known.variants or {}))[name] and name or (anonymous and "anon" or nil)
        local title = (last.name .. "-vs-now" .. (v and "-" .. v or "")):gsub("[^%w._-]", "_")
        after = { args = { "@" .. last.name, v }, pdf = vim.fs.joinpath(project.dir, "diff", title .. ".pdf"),
          to = vim.fs.joinpath(folder, "changes_since_" .. last.name .. ".pdf") }
      end
      job.range(88, 100)
      job.say("recording it (for diffs)")
      local texs = knit.parts(project, require("manuscript.export").cache(project, "submit"))
      require("manuscript.snapshot").record(project, folder, texs, {}, { kind = "submission", variant = name, anonymous = anonymous })

      local real = vim.tbl_filter(function(i) return not i.cited end, leaks)
      table.sort(leaks, function(x, y) -- (the traces first; self-citations after)
        if (x.cited or false) ~= (y.cited or false) then
          return not x.cited
        end
        return false
      end)
      if #leaks > 0 then
        vim.schedule(function()
          vim.fn.setqflist({}, " ", { title = "manuscript submit: anonymity", items = leaks })
          vim.cmd("botright copen")
          vim.cmd("wincmd p")
        end)
      end
      local notes = {}
      if not same then
        notes[#notes + 1] = "latex/ compiles into a different number of pages than manuscript.pdf"
      end
      if anonymous then
        notes[#notes + 1] = #real > 0 and ("%d possible traces of the authors (quickfix)"):format(#real)
          or "no trace of the authors" .. (#leaks > 0 and (" (%d in the bibliography: self-citations? in the quickfix list)"):format(#leaks) or "")
        if not vim.tbl_contains(extras, "title_page.pdf") then
          notes[#notes + 1] = "no title_page.tex (double-blind journals ask for a separate title page)"
        end
      end
      job.say(("%s ready%s"):format(vim.fn.fnamemodify(folder, ":~:."), #notes > 0 and ": " .. table.concat(notes, "; ") or ""))
    end)
    if not ok then
      knit.clean(project.dir)
      error(err, 0)
    end
  end, function(ok)
    if not (ok and after) then
      return on_done and on_done(ok)
    end
    require("manuscript.diff").run(after.args, function(diffed)
      if diffed then
        vim.uv.fs_copyfile(after.pdf, after.to)
      end
      if on_done then
        on_done(ok)
      end
    end)
  end, "submit")
end

return M
