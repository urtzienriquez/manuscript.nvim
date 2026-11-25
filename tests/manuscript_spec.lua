-- manuscript.nvim: finding a manuscript, knitting it part by part, exporting it to Word (a snapshot
-- of what was sent), and the tracked-changes PDF between two versions.
local job = require("manuscript.job")
local project_ = require("manuscript.project")
local knit = require("manuscript.knit")
local bib = require("manuscript.bib")
local diff = require("manuscript.diff")
project_.memory = vim.fn.tempname() .. ".json" -- (not the user's)

local messages = {}
vim.notify = function(m) messages[#messages + 1] = m end
vim.ui.open = function() end

-- Why a task failed: its messages, and LaTeX's errors (in the quickfix list).
local function why()
  local out = vim.tbl_map(tostring, messages)
  for _, item in ipairs(vim.fn.getqflist()) do
    out[#out + 1] = item.text
  end
  return table.concat(out, "\n")
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function read(path)
  local f = io.open(path)
  local text = f and f:read("*a")
  if f then
    f:close()
  end
  return text
end

-- runs start(on_done) (export.run, diff.run...), waited for: whether it ended well
local function run(start)
  local done, ok = false, nil
  start(function(r) ok, done = r, true end)
  assert(vim.wait(180000, function() return done end, 50), "it didn't end")
  return ok
end
local function export(done) require("manuscript.export").run(done) end

local BIB = [[
@article{smith2020,
  author = {Smith, A. and Lee, B. and Kim, C.},
  title = {Water loss in reptiles},
  journal = {J},
  doi = {10.1/abc},
  year = {2020},
}
@article{jones2019, author={Jones, D.}, title={Skin}, journal={E}, year={2019} }
]]

local TEX = [[
\documentclass{article}
\usepackage{authblk}
\usepackage{siunitx}
\title{A paper}
\author[1]{Ann Writer}
\affil[1]{Somewhere}
\begin{document}
\maketitle

Vipers lose water at 25\,\si{\celsius} \cite{smith2020,jones2019}.

The second paragraph.

\bibliographystyle{plain}
\bibliography{refs}
\end{document}
]]

-- a .tex manuscript in a git repository: its root's path
local function tex_project()
  local dir = vim.fn.tempname()
  write(dir .. "/paper.tex", TEX)
  write(dir .. "/refs.bib", BIB)
  vim.system({ "git", "init", "-q", dir }):wait()
  vim.system({ "git", "-C", dir, "add", "." }):wait()
  vim.system({ "git", "-C", dir, "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-qm", "first" }):wait()
  return dir .. "/paper.tex"
end

describe("a manuscript", function()
  it("is found from its root, a part (% !TeX root), or its folder", function()
    local dir = vim.fn.tempname()
    write(dir .. "/1_index.Rnw", "\\documentclass{article}\n\\addbibresource{refs.bib}\n\\begin{document}\n<<child='2_main.Rnw', eval=FALSE>>=\n@\n<<child='3_appendix1.Rnw'>>=\n@\n\\end{document}\n")
    write(dir .. "/2_main.Rnw", "% !TeX root = 1_index.Rnw\nText.\n")
    write(dir .. "/3_appendix1.Rnw", "More.\n")
    write(dir .. "/1_index.tex", "\\begin{document}\n") -- (its knitted output: not another root)
    write(dir .. "/refs.bib", BIB)
    for _, from in ipairs({ dir .. "/1_index.Rnw", dir .. "/2_main.Rnw", dir }) do
      assert.equals(dir .. "/1_index.Rnw", project_.root(from))
    end
    local p = project_.find(dir)
    assert.same({ "main", "appendix1" }, vim.tbl_map(function(x) return x.name end, p.parts))
    assert.same({ dir .. "/refs.bib" }, p.bibs)
    assert.is_true(p.rnw)
    write(dir .. "/other.Rnw", "\\begin{document}\n")
    local root, err = project_.root(vim.fn.tempname())
    assert.is_nil(root)
    assert.truthy(err)
  end)

  it("says so when the root a part names (% !TeX root) isn't there", function()
    local dir = vim.fn.tempname()
    write(dir .. "/2_main.Rnw", "% !TeX root = 1_index.Rnw\nText.\n")
    local ok, err = pcall(project_.find, dir .. "/2_main.Rnw")
    assert.is_false(ok)
    assert.truthy(err.msg:find("2_main.Rnw says its root is 1_index.Rnw (% !TeX root), but there's no 1_index.Rnw in", 1, true), err.msg)
  end)

  it("takes options from a .manuscript.lua in its folder", function()
    local path = tex_project()
    write(vim.fs.dirname(path) .. "/.manuscript.lua", "return { move_figures = true, dpi = 300 }")
    local p = project_.find(path)
    assert.is_true(p.options.move_figures)
    assert.equals(300, p.options.dpi)
    assert.is_false(p.options.move_tables)
  end)

  it("is knitted part by part: only that part's child chunk evaluated", function()
    local root = "\\begin{document}\n<<child='2_main.Rnw', eval=FALSE>>=\n@\n  <<eval=TRUE, child=\"3_app.Rnw\">>=\n@\n"
    local main = knit.root_for(root, "/d/2_main.Rnw", "/d")
    assert.truthy(main:find("<<child='2_main.Rnw', eval=TRUE>>=", 1, true))
    assert.truthy(main:find("  <<child=\"3_app.Rnw\", eval=FALSE>>=", 1, true))
    local all = knit.root_for(root, nil, "/d")
    assert.equals(2, select(2, all:gsub("eval=TRUE", "")))
  end)
end)

describe("the .bib", function()
  it("is read on one line or many; keys renamed since are found by DOI or title", function()
    local old = bib.parse(BIB .. "@comment{@article{x, title={no}}}\n")
    assert.same({ "jones2019", "smith2020" }, vim.fn.sort(vim.tbl_keys(old)))
    assert.equals("Skin", old.jones2019.fields.title)
    local new = bib.parse(BIB:gsub("smith2020", "smith2020a"):gsub("jones2019", "jones2019b"))
    assert.same({ smith2020 = "smith2020a", jones2019 = "jones2019b" }, bib.renames(old, new))
  end)
end)

describe("the citations of a version", function()
  it("are one list without spaces, renamed", function()
    local text = "\\parencite[see][p. 2]{a, b} and \\textcite{c} \\cite*{a,c}"
    assert.equals("\\parencite[see][p. 2]{z,b} and \\textcite{c} \\cite*{z,c}", diff.citations(text, { a = "z" }))
  end)
end)

describe("an export", function()
  it("is a Word file per part in export/<date>/, its LaTeX kept, nothing left in the folder", function()
    if not job.has("pandoc") then
      return pending("needs pandoc")
    end
    local path = tex_project()
    local dir = vim.fs.dirname(path)
    vim.cmd.edit(path)
    assert.is_true(run(export))
    local list = require("manuscript.snapshot").list(project_.find(path))
    assert.equals(1, #list)
    local folder = list[1].dir
    assert.equals(os.date("%Y-%m-%d"), list[1].name)
    assert.truthy(vim.uv.fs_stat(folder .. "/paper_" .. vim.fs.basename(folder) .. ".docx"))
    assert.truthy(vim.uv.fs_stat(folder .. "/.manuscript/all.tex"))
    assert.is_false(list[1].manifest.dirty)
    assert.equals(40, #list[1].manifest.commit)
    assert.equals("*\n", read(dir .. "/export/.gitignore"))
    assert.same({}, vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir)))
    -- in the Word file: the text, citations as written by citeproc, no path of yours
    local zip = require("neoffice.zip")
    local document = zip.read(folder .. "/paper_" .. vim.fs.basename(folder) .. ".docx", "word/document.xml")
    assert.truthy(document:find("Vipers lose water at 25", 1, true))
    assert.truthy(document:find("°C", 1, true))
    assert.truthy(document:find("Smith", 1, true))
    assert.falsy((document .. zip.read(folder .. "/paper_" .. vim.fs.basename(folder) .. ".docx", "docProps/custom.xml")):find(vim.fn.tempname():match("^(/[^/]+/)") or "/tmp/", 1, true))
    assert.equals(project_.find(path).root, project_.known()[1]) -- (remembered, for :Manuscript merge)
    -- another export that day: a folder of its own
    assert.is_true(run(export))
    assert.truthy(vim.uv.fs_stat(dir .. "/export/" .. os.date("%Y-%m-%d") .. "-2/paper_" .. os.date("%Y-%m-%d") .. "-2.docx"))
  end)

  it("of an .Rnw manuscript is knitted part by part, each part's Word file its own", function()
    if not job.has("pandoc") or not job.has("Rscript") or not job.has("latexmk") then
      return pending("needs pandoc, R and latexmk")
    end
    local dir = vim.fn.tempname()
    write(dir .. "/1_index.Rnw", table.concat({
      "\\documentclass{article}", "\\begin{document}",
      "<<setup, include=FALSE>>=", "x <- 21", "@",
      "<<child='2_main.Rnw', eval=FALSE>>=", "@", "<<child='3_appendix1.Rnw', eval=FALSE>>=", "@",
      "\\end{document}", "",
    }, "\n"))
    write(dir .. "/2_main.Rnw", "% !TeX root = 1_index.Rnw\n\\section{Main}\\label{sec:main}\nThe answer is \\Sexpr{2 * x}, see Section~\\ref{sec:app}.\n")
    write(dir .. "/3_appendix1.Rnw", "\\section{Appendix}\\label{sec:app}\nOnly in the appendix.\n")
    vim.cmd.edit(dir .. "/2_main.Rnw")
    assert.is_true(run(export), table.concat(vim.tbl_map(tostring, messages), "\n"))
    local s = require("manuscript.snapshot").list(project_.find(dir))[1]
    local zip = require("neoffice.zip")
    local snapshot = require("manuscript.snapshot")
    assert.equal(s.dir .. "/main_" .. s.name .. ".docx", snapshot.docx(s, "main")) -- (its date: a version)
    local main = zip.read(snapshot.docx(s, "main"), "word/document.xml")
    local appendix = zip.read(snapshot.docx(s, "appendix1"), "word/document.xml")
    assert.truthy(main:find("The answer is 42", 1, true))
    assert.falsy(main:find("Only in the appendix", 1, true))
    assert.truthy(appendix:find("Only in the appendix", 1, true))
    assert.truthy(read(s.dir .. "/.manuscript/all.tex"):find("Only in the appendix", 1, true))
    assert.truthy(read(dir .. "/1_index.Rnw"):find("eval=FALSE>>=", 1, true)) -- (the root as it was)
    assert.same({}, vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir)))
  end)

  it("keeps the sources too when they weren't committed", function()
    if not job.has("pandoc") then
      return pending("needs pandoc")
    end
    local path = tex_project()
    write(path, TEX:gsub("The second", "An uncommitted"))
    vim.cmd.edit(path)
    assert.is_true(run(export))
    local s = require("manuscript.snapshot").list(project_.find(path))[1]
    assert.is_true(s.manifest.dirty)
    assert.truthy(read(s.dir .. "/.manuscript/sources/paper.tex"):find("An uncommitted", 1, true))
  end)
end)

describe("the tracked-changes PDF", function()
  local function ready()
    return job.has("latexdiff") and job.has("latexmk") and job.has("pdflatex")
  end

  it("compares a git revision, an export, or a file with the manuscript now", function()
    if not ready() or not job.has("pandoc") then
      return pending("needs latexdiff, latexmk, pdflatex and pandoc")
    end
    local path = tex_project()
    local dir = vim.fs.dirname(path)
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex" }')
    vim.cmd.edit(path)
    assert.is_true(run(export))
    write(path, TEX:gsub("The second paragraph", "The rewritten paragraph"):gsub("jones2019", "jones2019b"))
    write(dir .. "/refs.bib", BIB:gsub("jones2019", "jones2019b"))
    local function check(args, name)
      messages = {}
      assert.is_true(run(function(done) require("manuscript.diff").run(args, done) end), why())
      local pdf = dir .. "/diff/" .. name .. ".pdf"
      assert.truthy(vim.uv.fs_stat(pdf), name .. ": " .. table.concat(vim.tbl_map(tostring, messages), "\n"))
      local tex = read(vim.fs.joinpath(require("manuscript.export").cache(project_.find(path), "diff"), "diff.tex"))
      assert.truthy(tex:find("\\DIFadd{rewritten}", 1, true) or tex:find("DIFadd{rewritten", 1, true))
      assert.falsy(tex:find("DIFdel{jones2019", 1, true)) -- (the renamed key: not a change)
      assert.same({}, vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir)))
    end
    check({}, os.date("%Y-%m-%d") .. "-vs-now") -- (the last export)
    check({ "HEAD" }, "HEAD-" .. vim.trim(vim.system({ "git", "-C", dir, "rev-parse", "--short", "HEAD" }, { text = true }):wait().stdout) .. "-vs-now")
    local old = vim.fn.tempname() .. "/old.tex"
    write(old, TEX:gsub("jones2019", "jones2019b"))
    check({ old }, "old-vs-now") -- (a file)
    -- again: its PDF not built anew (its LaTeX files kept, out of the folder), nor opened again
    local opened = {}
    vim.ui.open = function(p) opened[#opened + 1] = p end
    local pdf = dir .. "/diff/old-vs-now.pdf"
    local kept = vim.fs.joinpath(require("manuscript.export").cache(project_.find(path), "diff"), "latex", "old-vs-now")
    assert.truthy(vim.uv.fs_stat(kept .. "/_manuscript-diff.aux"))
    local before = read(kept .. "/_manuscript-diff.log")
    check({ old }, "old-vs-now")
    assert.equal(before, read(kept .. "/_manuscript-diff.log")) -- (no LaTeX run)
    assert.truthy(vim.uv.fs_stat(pdf))
    assert.same({}, opened)
    -- changed: built (once more), and still not opened again
    write(path, TEX:gsub("The second paragraph", "The rewritten paragraph, twice"):gsub("jones2019", "jones2019b"))
    check({ old }, "old-vs-now")
    assert.are_not.equal(before, read(kept .. "/_manuscript-diff.log"))
    assert.truthy(read(vim.fs.joinpath(require("manuscript.export").cache(project_.find(path), "diff"), "diff.tex")):find("twice", 1, true))
    assert.same({}, opened)
    -- a fatal LaTeX error: failed (not the last PDF, kept, as if new), and from scratch next time
    write(path, TEX:gsub("The second paragraph", "\\input{no-such-file} The rewritten paragraph"))
    messages = {}
    assert.is_false(run(function(done) require("manuscript.diff").run({ old }, done) end))
    assert.truthy(vim.iter(messages):any(function(m) return tostring(m):find("couldn't build the PDF", 1, true) end))
    assert.is_nil(vim.uv.fs_stat(kept .. "/_manuscript-diff.aux"))
    assert.same({}, vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir)))
    vim.ui.open = function() end
    messages = {}
    assert.is_false(run(function(done) require("manuscript.diff").run({ "@7" }, done) end))
    assert.truthy(vim.iter(messages):any(function(m) return tostring(m):find("no export @7", 1, true) end))
  end)
end)

describe("progress", function()
  local function events_of(fn, title)
    local events, done = {}, nil
    local au = vim.api.nvim_create_autocmd("Progress", {
      pattern = "manuscript",
      callback = function(ev) events[#events + 1] = vim.deepcopy(ev.data) end,
    })
    local notify = vim.notify
    vim.notify = function() end
    job.task(fn, function(ok) done = ok end, title)
    vim.wait(5000, function() return done ~= nil end)
    vim.notify = notify
    vim.api.nvim_del_autocmd(au)
    return events, done
  end

  it("is one message per task, updated in place (steps from a command's output too), done at the end", function()
    local stdout
    local events, ok = events_of(function()
      job.title("build main")
      job.say("knitting", 10)
      stdout = job.run({ "printf", "a\nb\n" }, { line = function(line) job.say("line " .. line) end }).stdout
      job.say("main.pdf ready")
    end, "build")
    assert.is_true(ok)
    assert.equal("a\nb\n", stdout)
    assert.same({ "knitting", "line a", "line b", "main.pdf ready" },
      vim.tbl_map(function(e) return (e.text[1]:gsub(" · .*", "")) end, events))
    for k, e in ipairs(events) do
      assert.equal(events[1].id, e.id)
      assert.equal("build main", e.title)
      assert.equal(k < #events and "running" or "success", e.status)
    end
    assert.equal(10, events[1].percent)
    assert.equal(100, events[#events].percent)
  end)

  it("runs tasks one after another (they share the manuscript's folder), the next saying it waits", function()
    local order, waiting, done = {}, nil, 0
    local au = vim.api.nvim_create_autocmd("Progress", {
      pattern = "manuscript",
      callback = function(ev)
        if ev.data.title == "diff" and ev.data.text[1]:find("^waiting") then
          waiting = ev.data.text[1]
        end
      end,
    })
    job.task(function()
      order[#order + 1] = "build starts"
      job.run({ "sleep", "0.3" })
      order[#order + 1] = "build ends"
    end, function() done = done + 1 end, "build main")
    job.task(function()
      order[#order + 1] = "diff starts"
      job.fail("no export")
    end, function() done = done + 1 end, "diff")
    job.task(function()
      order[#order + 1] = "export starts"
    end, function() done = done + 1 end, "export")
    local notify = vim.notify
    vim.notify = function() end
    vim.wait(5000, function() return done == 3 end)
    vim.notify = notify
    vim.api.nvim_del_autocmd(au)
    assert.same({ "build starts", "build ends", "diff starts", "export starts" }, order)
    assert.equal("waiting for build main", waiting)
  end)

  it("ends as failed when the task fails", function()
    local events, ok = events_of(function()
      job.say("knitting")
      job.fail("knitting main failed")
    end, "build")
    assert.is_false(ok)
    assert.equal("failed", events[#events].status)
    assert.equal("failed", events[#events].text[1])
  end)
end)

describe("the tracked-changes PDF of a part", function()
  it("compares only that part: with the last export, or with a git revision", function()
    if not job.has("Rscript") or not job.has("latexdiff") or not job.has("latexmk") or not job.has("pandoc") then
      return pending("needs R, latexdiff, latexmk and pandoc")
    end
    local dir = vim.fn.tempname()
    write(dir .. "/1_index.Rnw", table.concat({
      "\\documentclass{article}", "\\begin{document}",
      "<<child='2_main.Rnw', eval=FALSE>>=", "@", "<<child='3_appendix1.Rnw', eval=FALSE>>=", "@",
      "\\end{document}", "",
    }, "\n"))
    write(dir .. "/2_main.Rnw", "% !TeX root = 1_index.Rnw\n\\section{Main}\nThe main text, first written.\n")
    write(dir .. "/3_appendix1.Rnw", "\\section{Appendix}\nThe appendix, first written.\n")
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex" }')
    vim.system({ "git", "init", "-q", dir }):wait()
    vim.system({ "git", "-C", dir, "add", "." }):wait()
    vim.system({ "git", "-C", dir, "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-qm", "first" }):wait()
    vim.cmd.edit(dir .. "/2_main.Rnw")
    assert.is_true(run(export))
    write(dir .. "/2_main.Rnw", "% !TeX root = 1_index.Rnw\n\\section{Main}\nThe main text, rewritten.\n")
    write(dir .. "/3_appendix1.Rnw", "\\section{Appendix}\nThe appendix, rewritten.\n")
    local function check(args, pdf, changed, unchanged)
      messages = {}
      assert.is_true(run(function(done) require("manuscript.diff").run(args, done) end), table.concat(vim.tbl_map(tostring, messages), "\n"))
      assert.truthy(vim.uv.fs_stat(dir .. "/diff/" .. pdf .. ".pdf"), pdf)
      local tex = read(vim.fs.joinpath(require("manuscript.export").cache(project_.find(dir), "diff"), "diff.tex"))
      assert.truthy(tex:find(changed, 1, true), changed)
      assert.falsy(tex:find(unchanged, 1, true), unchanged)
      assert.same({}, vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir)))
    end
    local commit = vim.trim(vim.system({ "git", "-C", dir, "rev-parse", "--short", "HEAD" }, { text = true }):wait().stdout)
    check({ "main" }, "main-" .. os.date("%Y-%m-%d") .. "-vs-now", "The main text", "The appendix")
    check({ "appendix1", "HEAD" }, "appendix1-HEAD-" .. commit .. "-vs-now", "The appendix", "The main text")
    assert.truthy(vim.tbl_contains(require("manuscript.versions").names(), "appendix1")) -- (completed)
  end)
end)

describe("a build", function()
  local build = require("manuscript.build")
  local function make(args)
    messages = {}
    return run(function(done) build.run(args or {}, done) end)
  end

  it("of a .tex manuscript is its PDF; LaTeX errors go to the quickfix list, at their source line", function()
    if not job.has("latexmk") or not job.has("pdflatex") then
      return pending("needs latexmk and pdflatex")
    end
    local path = tex_project()
    local dir = vim.fs.dirname(path)
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex" }')
    vim.cmd.edit(path)
    assert.is_true(make(), why())
    assert.truthy(vim.uv.fs_stat(dir .. "/paper.pdf"))
    write(path, TEX:gsub("The second paragraph", "The \\nocommand paragraph"))
    assert.is_false(make())
    vim.wait(100)
    local items = vim.fn.getqflist()
    assert.equals(1, #items)
    assert.equals("paper.tex", vim.fs.basename(vim.fn.bufname(items[1].bufnr)))
    assert.equals(12, items[1].lnum)
    assert.truthy(items[1].text:find("Undefined control sequence", 1, true))
    write(path, TEX)
    assert.is_true(make())
    vim.wait(100)
    assert.equals(0, #vim.fn.getqflist()) -- (its errors: gone)
    -- under another name: its own PDF (and latexmk's files), the usual one as it was; cleaned too
    local before = read(dir .. "/paper.pdf")
    write(path, TEX:gsub("The second paragraph", "The second version"))
    assert.is_true(make({ "paper_v2.pdf" }))
    assert.truthy(vim.uv.fs_stat(dir .. "/paper_v2.pdf"))
    assert.equal(before, read(dir .. "/paper.pdf"))
    assert.truthy(vim.uv.fs_stat(dir .. "/paper_v2.aux"))
    assert.is_false(make({ "../elsewhere.pdf" }))
    build.clean({}, true)
    assert.is_nil(vim.uv.fs_stat(dir .. "/paper_v2.aux"))
    assert.truthy(vim.uv.fs_stat(dir .. "/paper_v2.pdf"))
    write(path, TEX)
    local order = {} -- (two at once: the second after the first)
    build.run({}, function() order[#order + 1] = 1 end)
    build.run({}, function() order[#order + 1] = 2 end)
    assert.truthy(vim.wait(120000, function() return #order == 2 end, 50))
    assert.same({ 1, 2 }, order)
  end)

  it("of an .Rnw part knits only it, after the whole once (for the numbers of its references)", function()
    if not job.has("Rscript") or not job.has("latexmk") then
      return pending("needs R and latexmk")
    end
    local dir = vim.fn.tempname()
    write(dir .. "/1_index.Rnw", table.concat({
      "\\documentclass{article}", "\\begin{document}",
      "<<child='2_main.Rnw', eval=FALSE>>=", "@", "<<child='3_appendix1.Rnw', eval=FALSE>>=", "@",
      "\\end{document}", "",
    }, "\n"))
    write(dir .. "/2_main.Rnw", "% !TeX root = 1_index.Rnw\n\\section{Main}\nSee Section~\\ref{sec:app}: \\Sexpr{6 * 7}.\n")
    write(dir .. "/3_appendix1.Rnw", "\\section{Appendix}\\label{sec:app}\nOnly in the appendix.\n")
    vim.cmd.edit(dir .. "/2_main.Rnw")
    assert.is_true(make(), table.concat(vim.tbl_map(tostring, messages), "\n"))
    assert.truthy(vim.uv.fs_stat(dir .. "/main.pdf"))
    assert.truthy(vim.uv.fs_stat(dir .. "/1_index.pdf")) -- (the whole, first)
    assert.truthy(vim.uv.fs_stat(dir .. "/1_index-labels.aux"))
    local main = read(dir .. "/main.tex")
    assert.truthy(main:find("See Section~2: 42", 1, true)) -- (its reference to the appendix: numbered)
    assert.falsy(main:find("Only in the appendix", 1, true))
    assert.same({}, vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir)))
    assert.truthy(read(dir .. "/1_index.Rnw"):find("eval=FALSE>>=", 1, true))
    -- cleaned: a part's build alone, or all of them (and the labels of the whole); .tex and PDF stay
    write(dir .. "/main.synctex.gz", "")
    local function aux(name)
      return vim.tbl_filter(function(n)
        return vim.startswith(n, name .. ".") and not n:match("%.tex$") and not n:match("%.pdf$") and not n:match("%.Rnw$")
      end, vim.fn.readdir(dir))
    end
    assert.truthy(#aux("main") > 0 and #aux("1_index") > 0)
    build.clean({ "main" }, true)
    assert.same({}, aux("main"))
    assert.truthy(#aux("1_index") > 0)
    assert.truthy(vim.uv.fs_stat(dir .. "/1_index-labels.aux"))
    build.clean({}, true)
    assert.same({}, aux("1_index"))
    assert.is_nil(vim.uv.fs_stat(dir .. "/1_index-labels.aux"))
    for _, kept in ipairs({ "main.tex", "main.pdf", "1_index.tex", "1_index.pdf" }) do
      assert.truthy(vim.uv.fs_stat(dir .. "/" .. kept), kept)
    end
    -- a part under another name: main_v2.tex and .pdf, main.pdf as it was; another part's name: no
    local main_pdf = read(dir .. "/main.pdf")
    write(dir .. "/2_main.Rnw", "% !TeX root = 1_index.Rnw\n\\section{Main}\nSee Section~\\ref{sec:app}: \\Sexpr{6*7}. Second version.\n")
    assert.is_true(make({ "main", "main_v2.pdf" }), table.concat(vim.tbl_map(tostring, messages), "\n"))
    assert.truthy(read(dir .. "/main_v2.tex"):find("Second version", 1, true))
    assert.truthy(read(dir .. "/main_v2.tex"):find("See Section~2: 42", 1, true))
    assert.truthy(vim.uv.fs_stat(dir .. "/main_v2.pdf"))
    assert.equal(main_pdf, read(dir .. "/main.pdf"))
    assert.is_false(make({ "main", "appendix1.pdf" }))
    assert.truthy(#aux("main_v2") > 0)
    build.clean({ "main_v2" }, true)
    assert.same({}, aux("main_v2"))
    assert.same({}, vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir)))
  end)
end)

