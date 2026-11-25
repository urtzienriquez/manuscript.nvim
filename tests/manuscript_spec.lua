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
    assert.equal("rnw", p.kind)
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

describe("a manuscript of each kind", function()
  local function names(list, dir)
    return vim.tbl_map(function(f) return f:sub(#dir + 2) end, list)
  end

  it("in LaTeX, of several files: \\include{} files are parts (the root too, with text of its own), \\input{} files are its text", function()
    local dir = vim.fn.tempname()
    write(dir .. "/paper.tex", table.concat({
      "\\documentclass{article}", "\\input{preamble}", "\\addbibresource{refs.bib}",
      "\\begin{document}", "\\maketitle", "\\input{intro}", "% \\input{old}",
      "\\include{appendix1}", "\\printbibliography", "\\end{document}", "",
    }, "\n"))
    write(dir .. "/preamble.tex", "\\usepackage{biblatex}\n")
    write(dir .. "/intro.tex", "The introduction.\n\\input{sections/methods}\n")
    write(dir .. "/sections/methods.tex", "The methods.\n")
    write(dir .. "/appendix1.tex", "The appendix.\n")
    write(dir .. "/old.tex", "Commented out.\n")
    write(dir .. "/refs.bib", "")
    for _, from in ipairs({ "paper.tex", "intro.tex", "sections/methods.tex", "appendix1.tex", "" }) do
      local p = project_.find(dir .. "/" .. from)
      assert.equal(dir .. "/paper.tex", p.root, from)
    end
    local p = project_.find(dir)
    assert.equal("tex", p.kind)
    assert.same({ { name = "main", file = dir .. "/paper.tex" }, { name = "appendix1", file = dir .. "/appendix1.tex" } }, p.parts)
    assert.same({ "paper.tex", "preamble.tex", "intro.tex", "sections/methods.tex", "appendix1.tex" }, names(p.files, dir))
    assert.same({ dir .. "/refs.bib" }, p.bibs)
    -- flattened: the files' text in place (an \\include between page breaks), the commented one not
    local flat = project_.flatten(read(dir .. "/paper.tex"), dir)
    assert.truthy(flat:find("\\usepackage{biblatex}\n", 1, true))
    assert.truthy(flat:find("The introduction.\nThe methods.\n", 1, true))
    assert.truthy(flat:find("\\clearpage\nThe appendix.\n\n\\clearpage", 1, true))
    assert.truthy(flat:find("% \\input{old}", 1, true))
    assert.falsy(flat:find("Commented out", 1, true))
    -- only \\include{}s, no text of its own: they are the parts
    write(dir .. "/paper.tex", "\\documentclass{article}\n\\begin{document}\n\\maketitle\n\\include{appendix1}\n\\include{intro}\n\\printbibliography\n\\end{document}\n")
    assert.same({ "appendix1", "intro" }, vim.tbl_map(function(x) return x.name end, project_.find(dir).parts))
  end)

  it("in LaTeX, of one file: the file is the manuscript, a standalone figure beside others too", function()
    local dir = vim.fn.tempname()
    write(dir .. "/fig1.tex", "\\documentclass{standalone}\n\\begin{document}A\\end{document}\n")
    write(dir .. "/fig2.tex", "\\documentclass{standalone}\n\\begin{document}B\\end{document}\n")
    local p = project_.find(dir .. "/fig2.tex")
    assert.equal(dir .. "/fig2.tex", p.root)
    assert.same({ { name = "fig2", file = dir .. "/fig2.tex" } }, p.parts)
    local ok, err = pcall(project_.find, dir)
    assert.is_false(ok)
    assert.truthy(err.msg:find("several manuscripts", 1, true))
  end)

  it("in R Markdown: the .Rmd with a YAML header, its child chunks the parts, its YAML bibliography", function()
    local dir = vim.fn.tempname()
    local bib = vim.fn.tempname() .. "/zotero.bib"
    write(bib, "")
    write(dir .. "/0-index.Rmd", table.concat({
      "---", 'title: "A paper"', "bibliography:", "  - " .. bib, "  - ./packages.bib", "output:",
      "  bookdown::pdf_document2:", "    keep_tex: true", "---", "", "```{r setup, include=FALSE}", "x <- 1", "```", "",
      '```{r child="./1-main-text.Rmd", eval=params$render_main}', "```", "",
      "```{r, child='2-appendix1.Rmd'}", "```", "",
    }, "\n"))
    write(dir .. "/1-main-text.Rmd", "# Introduction\n\nText [@smith2020].\n")
    write(dir .. "/2-appendix1.Rmd", "# Appendix\n")
    write(dir .. "/packages.bib", "")
    write(dir .. "/0-index.tex", "\\documentclass{article}\\begin{document}\\end{document}") -- (its knitted output)
    for _, from in ipairs({ "1-main-text.Rmd", "2-appendix1.Rmd", "0-index.Rmd", "" }) do
      assert.equal(dir .. "/0-index.Rmd", project_.find(dir .. "/" .. from).root, from)
    end
    local p = project_.find(dir)
    assert.equal("rmd", p.kind)
    assert.same({ "main-text", "appendix1" }, vim.tbl_map(function(x) return x.name end, p.parts))
    assert.same({ "0-index.Rmd", "1-main-text.Rmd", "2-appendix1.Rmd" }, names(p.files, dir))
    assert.same(vim.fn.sort({ bib, dir .. "/packages.bib" }), p.bibs)
  end)

  it("in Rnoweb: its child chunks the parts; files named for texlab's sake (\\iftexlab) are its files, not inlined", function()
    local dir = vim.fn.tempname()
    write(dir .. "/1_index.Rnw", table.concat({
      "\\documentclass{article}", "\\newif\\iftexlab", "\\iftexlab", "  \\input{2_main.Rnw}", "\\fi",
      "\\begin{document}", "<<child='2_main.Rnw'>>=", "@", "<<child='3_appendix1.Rnw'>>=", "@",
      "<<child='4_appendix2.Rnw'>>=", "@", "<<child='5_appendix3.Rnw'>>=", "@", "\\end{document}", "",
    }, "\n"))
    write(dir .. "/2_main.Rnw", "Text, \\input{table1}.\n")
    for k = 1, 3 do
      write(dir .. ("/%d_appendix%d.Rnw"):format(k + 2, k), "An appendix.\n")
    end
    write(dir .. "/table1.tex", "A table.\n")
    local p = project_.find(dir .. "/2_main.Rnw")
    assert.equal("rnw", p.kind)
    assert.same({ "main", "appendix1", "appendix2", "appendix3" }, vim.tbl_map(function(x) return x.name end, p.parts)) -- (in order)
    assert.same({ "1_index.Rnw", "2_main.Rnw", "table1.tex", "3_appendix1.Rnw", "4_appendix2.Rnw", "5_appendix3.Rnw" }, names(p.files, dir))
    assert.truthy(project_.flatten(read(dir .. "/1_index.Rnw"), dir):find("\\input{2_main.Rnw}", 1, true))
  end)
end)

describe("the numbers of references to other parts", function()
  it("come from the whole's .aux (and its \\include{}s'), for labels the part doesn't define", function()
    local dir = vim.fn.tempname()
    write(dir .. "/paper.aux", "\\relax\n\\newlabel{sec:app}{{2}{5}{Appendix}{section.2}{}}\n\\newlabel{eq:one}{{3}{6}}\n\\@input{appendix1.aux}\n")
    write(dir .. "/appendix1.aux", "\\newlabel{appendix1}{{Appendix 1}{27}{References}{appendix.1}{}}\n\\newlabel{sec:own}{{9}{9}}\n")
    local labels = require("manuscript.labels")
    local l = labels.read(dir .. "/paper.aux")
    assert.same({ num = "Appendix 1", page = "27" }, l.appendix1)
    local tex = "See \\textbf{\\ref{appendix1}}, Section~\\ref{sec:app} on page \\pageref{sec:app}, \\eqref{eq:one}; "
      .. "\\ref{sec:own}, \\ref{nowhere}. \\label{sec:own}\\refstepcounter{x}"
    assert.equal("See \\textbf{Appendix 1}, Section~2 on page 5, (3); \\ref{sec:own}, \\ref{nowhere}. \\label{sec:own}\\refstepcounter{x}",
      labels.resolve(tex, l))
    -- a label in a comment isn't one the text defines
    assert.equals("% \\label{sec:app} there\nSee 2.", labels.resolve("% \\label{sec:app} there\nSee \\ref{sec:app}.", l))
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
      local tex = read(dir .. "/.build/diff/" .. name .. ".tex")
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
    local kept = dir .. "/.build/diff"
    assert.truthy(vim.uv.fs_stat(kept .. "/old-vs-now.aux"))
    local before = read(kept .. "/old-vs-now.log")
    check({ old }, "old-vs-now")
    assert.equal(before, read(kept .. "/old-vs-now.log")) -- (no LaTeX run)
    assert.truthy(vim.uv.fs_stat(pdf))
    assert.same({}, opened)
    -- changed: built (once more), and still not opened again
    write(path, TEX:gsub("The second paragraph", "The rewritten paragraph, twice"):gsub("jones2019", "jones2019b"))
    check({ old }, "old-vs-now")
    assert.are_not.equal(before, read(kept .. "/old-vs-now.log"))
    assert.truthy(read(kept .. "/old-vs-now.tex"):find("twice", 1, true))
    assert.same({}, opened)
    -- a fatal LaTeX error: failed (not the last PDF, kept, as if new), and from scratch next time
    write(path, TEX:gsub("The second paragraph", "\\input{no-such-file} The rewritten paragraph"))
    messages = {}
    assert.is_false(run(function(done) require("manuscript.diff").run({ old }, done) end))
    assert.truthy(vim.iter(messages):any(function(m) return tostring(m):find("couldn't build the PDF", 1, true) end))
    assert.is_nil(vim.uv.fs_stat(kept .. "/old-vs-now.aux"))
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
      local tex = read(dir .. "/.build/diff/" .. pdf .. ".tex")
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

describe("a build of each kind, by parts", function()
  local function make(args)
    messages = {}
    return run(function(done) require("manuscript.build").run(args or {}, done) end)
  end
  local function text_of(pdf)
    return vim.system({ "pdftotext", pdf, "-" }, { text = true }):wait().stdout or ""
  end
  local function leftovers(dir)
    return vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir))
  end

  it("in LaTeX: an \\include{} part, or the root's own text, alone; references to the other numbered", function()
    if not job.has("latexmk") or not job.has("pdflatex") or not job.has("pdftotext") then
      return pending("needs latexmk, pdflatex and pdftotext")
    end
    local dir = vim.fn.tempname()
    write(dir .. "/paper.tex", table.concat({
      "\\documentclass{article}", "\\begin{document}", "\\section{Main}\\label{sec:main}", "\\input{intro}",
      "See Appendix~\\ref{sec:app}.", "\\include{appendix1}", "\\end{document}", "",
    }, "\n"))
    write(dir .. "/intro.tex", "The introduction.\n")
    write(dir .. "/appendix1.tex", "\\section{Appendix}\\label{sec:app}\nOnly in the appendix; see Section~\\ref{sec:main}.\n")
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex" }')
    vim.cmd.edit(dir .. "/intro.tex")
    assert.is_true(make(), why())
    local main = text_of(dir .. "/main.pdf")
    assert.truthy(main:find("The introduction", 1, true))
    assert.truthy(main:find("See Appendix 2", 1, true), main)
    assert.falsy(main:find("Only in the appendix", 1, true))
    assert.truthy(vim.uv.fs_stat(dir .. "/paper.pdf")) -- (the whole, first: for the numbers)
    vim.cmd.edit(dir .. "/appendix1.tex")
    assert.is_true(make(), why())
    local appendix = text_of(dir .. "/appendix1.pdf")
    assert.truthy(appendix:find("Only in the appendix; see Section 1", 1, true), appendix)
    assert.falsy(appendix:find("The introduction", 1, true))
    -- the whole's files as they were (its \\include{}'s appendix1.aux is its own), nothing left over
    assert.truthy(read(dir .. "/.build/paper/appendix1.aux"):find("\\newlabel{sec:app}", 1, true))
    assert.is_nil(vim.uv.fs_stat(dir .. "/main.aux"))
    assert.same({}, leftovers(dir))
    assert.is_true(make({ "all" }), why())
    assert.truthy(text_of(dir .. "/paper.pdf"):find("Only in the appendix", 1, true))
  end)

  it("in R Markdown: rendered with its YAML's format, a child alone, references to the other numbered", function()
    if not job.has("latexmk") or not job.has("pdflatex") or not job.has("pdftotext") or not job.has("Rscript")
      or vim.trim(vim.system({ "Rscript", "-e", "cat(requireNamespace('rmarkdown', quietly = TRUE))" }, { text = true }):wait().stdout or "") ~= "TRUE" then
      return pending("needs R with rmarkdown, latexmk, pdflatex and pdftotext")
    end
    local dir = vim.fn.tempname()
    write(dir .. "/0-index.Rmd", table.concat({
      "---", 'title: "A paper"', "output:", "  pdf_document:", "    number_sections: true", "    latex_engine: pdflatex", "---", "",
      "```{r child='1-main.Rmd'}", "```", "", "```{r child='2-appendix.Rmd'}", "```", "",
    }, "\n"))
    write(dir .. "/1-main.Rmd", "# Main {#sec:main}\n\nThe answer is `r 6 * 7`; see Section \\ref{sec:app}.\n")
    write(dir .. "/2-appendix.Rmd", "# Appendix {#sec:app}\n\nOnly in the appendix.\n")
    vim.cmd.edit(dir .. "/1-main.Rmd")
    assert.is_true(make(), why())
    local main = text_of(dir .. "/main.pdf")
    assert.truthy(main:find("The answer is 42; see Section 2", 1, true), main)
    assert.falsy(main:find("Only in the appendix", 1, true))
    assert.truthy(vim.uv.fs_stat(dir .. "/0-index.pdf"))
    assert.same({}, leftovers(dir))
    assert.truthy(read(dir .. "/0-index.Rmd"):find("child='1-main.Rmd'}", 1, true)) -- (the root as it was)
  end)
end)

describe("an export and a diff of each kind", function()
  local zip = function(path, entry) return require("neoffice.zip").read(path, entry) or "" end
  local function commit(dir, message)
    vim.system({ "git", "-C", dir, "add", "." }):wait()
    vim.system({ "git", "-C", dir, "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-qm", message }):wait()
  end
  local function diff(args)
    messages = {}
    return run(function(done) require("manuscript.diff").run(args, done) end)
  end
  local function diff_tex(dir) -- (the last diff's LaTeX)
    local newest, at = nil, -1
    for file in vim.fs.dir(dir .. "/.build/diff") do
      local st = file:match("%.tex$") and vim.uv.fs_stat(dir .. "/.build/diff/" .. file)
      if st and st.mtime.sec + st.mtime.nsec / 1e9 > at then
        newest, at = file, st.mtime.sec + st.mtime.nsec / 1e9
      end
    end
    return read(dir .. "/.build/diff/" .. newest)
  end
  local function has_rmarkdown()
    return job.has("Rscript") and vim.trim(vim.system({ "Rscript", "-e", "cat(requireNamespace('rmarkdown', quietly = TRUE))" }, { text = true }):wait().stdout or "") == "TRUE"
  end

  it("in LaTeX of several files: a Word file per part, \\input{}s in; changes in an \\input{} file, and in files gone since", function()
    if not job.has("pandoc") or not job.has("latexmk") or not job.has("pdflatex") or not job.has("latexdiff") then
      return pending("needs pandoc, latexmk, pdflatex and latexdiff")
    end
    local dir = vim.fn.tempname()
    write(dir .. "/paper.tex", table.concat({
      "\\documentclass{article}", "\\begin{document}", "\\section{Main}\\label{sec:main}", "\\input{intro}",
      "\\input{gone}", "See Appendix~\\ref{sec:app}.", "\\include{appendix1}", "\\end{document}", "",
    }, "\n"))
    write(dir .. "/intro.tex", "The introduction, first written.\n")
    write(dir .. "/gone.tex", "A paragraph later removed.\n")
    write(dir .. "/appendix1.tex", "\\section{Appendix}\\label{sec:app}\nOnly in the appendix.\n")
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex" }')
    vim.system({ "git", "init", "-q", dir }):wait()
    commit(dir, "first")
    vim.cmd.edit(dir .. "/intro.tex")
    assert.is_true(run(export), why())
    local s = require("manuscript.snapshot").list(project_.find(dir))[1]
    local snapshot = require("manuscript.snapshot")
    local main = zip(snapshot.docx(s, "main"), "word/document.xml")
    local appendix = zip(snapshot.docx(s, "appendix1"), "word/document.xml")
    assert.truthy(main:find("The introduction, first written.", 1, true))
    assert.truthy(main:find("See Appendix[^<]*2%."), main:match("See Appendix.-</w:p>")) -- (numbered)
    assert.falsy(main:find("Only in the appendix", 1, true))
    assert.truthy(appendix:find("Only in the appendix", 1, true))
    assert.falsy(appendix:find("The introduction", 1, true))
    -- changed since: an \\input{} file edited, another gone
    write(dir .. "/intro.tex", "The introduction, rewritten.\n")
    write(dir .. "/paper.tex", (read(dir .. "/paper.tex"):gsub("\\input{gone}\n", "")))
    os.remove(dir .. "/gone.tex")
    assert.is_true(diff({}), why())
    local tex = diff_tex(dir)
    assert.truthy(tex:find("DIFadd{rewritten", 1, true), tex:match("The introduction.-\n"))
    assert.truthy(tex:find("DIFdel{A paragraph later removed", 1, true) or tex:find("A paragraph later removed", 1, true))
    assert.is_true(diff({ "HEAD" }), why())
    tex = diff_tex(dir)
    assert.truthy(tex:find("A paragraph later removed", 1, true)) -- (the old version's file, from git)
    assert.truthy(tex:find("DIFadd{rewritten", 1, true))
    assert.is_true(diff({ "appendix1", "HEAD" }), why())
    assert.falsy(diff_tex(dir):find("The introduction", 1, true))
    assert.same({}, vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir)))
  end)

  it("in R Markdown: a Word file per child, knitted, with its R figures; a part's diff with a revision", function()
    if not has_rmarkdown() or not job.has("pandoc") or not job.has("latexmk") or not job.has("pdflatex") or not job.has("latexdiff") then
      return pending("needs R with rmarkdown, pandoc, latexmk, pdflatex and latexdiff")
    end
    local dir = vim.fn.tempname()
    write(dir .. "/0-index.Rmd", table.concat({
      "---", 'title: "A paper"', "output:", "  pdf_document:", "    number_sections: true", "    latex_engine: pdflatex", "---", "",
      "```{r child='1-main.Rmd'}", "```", "", "```{r child='2-appendix.Rmd'}", "```", "",
    }, "\n"))
    write(dir .. "/1-main.Rmd", "# Main {#sec:main}\n\nThe answer is `r 6 * 7`, first written.\n\n```{r points, fig.cap='Some points.'}\nplot(1:3)\n```\n")
    write(dir .. "/2-appendix.Rmd", "# Appendix {#sec:app}\n\nOnly in the appendix.\n")
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex" }')
    vim.system({ "git", "init", "-q", dir }):wait()
    commit(dir, "first")
    vim.cmd.edit(dir .. "/1-main.Rmd")
    assert.is_true(run(export), why())
    local snapshot = require("manuscript.snapshot")
    local s = snapshot.list(project_.find(dir))[1]
    local docx = snapshot.docx(s, "main-text") -- (no such part: main)
    docx = vim.uv.fs_stat(docx) and docx or snapshot.docx(s, "main")
    local main = zip(docx, "word/document.xml")
    assert.truthy(main:find("The answer is 42, first written.", 1, true), main:sub(1, 400))
    assert.truthy(main:find("<pic:pic", 1, true) or main:find("<w:drawing", 1, true)) -- (its figure)
    assert.falsy(main:find("Only in the appendix", 1, true))
    assert.truthy(zip(snapshot.docx(s, "appendix"), "word/document.xml"):find("Only in the appendix", 1, true))
    write(dir .. "/1-main.Rmd", (read(dir .. "/1-main.Rmd"):gsub("first written", "rewritten")))
    assert.is_true(diff({ "main", "HEAD" }), why())
    local tex = diff_tex(dir)
    assert.truthy(tex:find("DIFadd{rewritten", 1, true))
    assert.falsy(tex:find("Only in the appendix", 1, true))
    assert.same({}, vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir)))
  end)

  it("in Rnoweb: a part's \\input{} files in its Word file", function()
    if not job.has("pandoc") or not job.has("Rscript") then
      return pending("needs pandoc and R")
    end
    local dir = vim.fn.tempname()
    write(dir .. "/1_index.Rnw", table.concat({
      "\\documentclass{article}", "\\begin{document}", "<<child='2_main.Rnw'>>=", "@", "\\end{document}", "",
    }, "\n"))
    write(dir .. "/2_main.Rnw", "The main text.\n\n\\input{table1}\n")
    write(dir .. "/table1.tex", "A table, from its own file.\n")
    vim.cmd.edit(dir .. "/2_main.Rnw")
    assert.is_true(run(export), why())
    local snapshot = require("manuscript.snapshot")
    local s = snapshot.list(project_.find(dir))[1]
    assert.truthy(zip(snapshot.docx(s, "main"), "word/document.xml"):find("A table, from its own file.", 1, true))
  end)
end)

describe("knitted the same way: .jnw (Knit.jl, in its worker) and .Rmd (knitrmini)", function()
  local function make(args)
    messages = {}
    return run(function(done) require("manuscript.build").run(args or {}, done) end)
  end
  local function text_of(pdf)
    return vim.system({ "pdftotext", pdf, "-" }, { text = true }):wait().stdout or ""
  end
  local function leftovers(dir)
    return vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir))
  end
  local function has_knit_jl()
    if not job.has("julia") then
      return false
    end
    local r = vim.system({ "julia", "--startup-file=no", "-e", "using Knit; print(isdefined(Knit, :serve))" }, { text = true }):wait()
    return vim.trim(r.stdout or "") == "true"
  end
  local function has_knitrmini_rmd()
    local r = job.has("Rscript") and vim.system({ "Rscript", "-e",
      'cat(requireNamespace("knitrmini", quietly = TRUE) && exists("render_markdown_latex", asNamespace("knitrmini")))' }, { text = true }):wait()
    return r and vim.trim(r.stdout or "") == "TRUE"
  end

  it("says why the Julia worker exited: Knit.jl missing or too old, else Julia's error", function()
    local reason = require("manuscript.worker").reason
    local old = "ERROR: UndefVarError: `serve` not defined in `Knit`\nStacktrace:\n [1] getproperty"
    assert.matches("too old", reason(1, old))
    assert.matches("isn't installed", reason(1, "ERROR: ArgumentError: Package Knit not found in current path."))
    assert.equals("Julia exited (1): ERROR: LoadError: boom", reason(1, "noise\nERROR: LoadError: boom\nStacktrace:\n [1] x"))
    assert.matches("knitrmini R loads is too old", reason(1, "Error: 'serve' is not an exported object from 'namespace:knitrmini'", "r"))
    assert.equals("R exited (1): Error in f(): boom", reason(1, "Error in f(): boom", "r"))
  end)

  it("a .jnw paper: a part built alone in the Julia worker, its references numbered; exported", function()
    if not job.has("latexmk") or not job.has("pdflatex") or not job.has("pdftotext") or not job.has("pandoc") or not has_knit_jl() then
      return pending("needs Julia with Knit.jl (serve), latexmk, pdflatex, pdftotext and pandoc")
    end
    local dir = vim.fn.tempname()
    write(dir .. "/1_index.jnw", table.concat({
      "\\documentclass{article}", "\\begin{document}", "<<setup>>=", "n = 7", "@",
      "<<main, child='2_main.jnw'>>=", "@", "<<appendix, child='3_appendix.jnw'>>=", "@", "\\end{document}", "",
    }, "\n"))
    write(dir .. "/2_main.jnw", "\\section{Main}\\label{sec:main}\nSeven is \\Sexpr{n}; see Appendix~\\ref{sec:app}.\n")
    write(dir .. "/3_appendix.jnw", "\\section{Appendix}\\label{sec:app}\nOnly in the appendix.\n")
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex" }')
    vim.cmd.edit(dir .. "/2_main.jnw")
    assert.is_true(make(), why())
    local main = text_of(dir .. "/main.pdf")
    assert.truthy(main:find("Seven is 7; see Appendix 2", 1, true), main)
    assert.falsy(main:find("Only in the appendix", 1, true))
    assert.truthy(vim.uv.fs_stat(dir .. "/.build/1_index-labels.aux")) -- (the snapshot of the whole, built first)
    assert.same({}, leftovers(dir))
    assert.is_true(run(export), why())
    local snapshot = require("manuscript.snapshot")
    local s = snapshot.list(project_.find(dir))[1]
    local doc = require("neoffice.zip").read(snapshot.docx(s, "main"), "word/document.xml") or ""
    assert.truthy(doc:find("Seven is 7", 1, true))
    assert.falsy(doc:find("Only in the appendix", 1, true))
  end)

  it("an .Rmd paper without an output format: knitrmini, as an .Rnw (its parts, its snapshot)", function()
    if not job.has("latexmk") or not job.has("pdflatex") or not job.has("pdftotext") or not job.has("pandoc") or not has_knitrmini_rmd() then
      return pending("needs knitrmini with R Markdown, latexmk, pdflatex, pdftotext and pandoc")
    end
    local dir = vim.fn.tempname()
    write(dir .. "/0-index.Rmd", table.concat({
      "---", "documentclass: article", "---", "",
      "```{r child='1-main.Rmd'}", "```", "", "```{r child='2-appendix.Rmd'}", "```", "",
    }, "\n"))
    write(dir .. "/1-main.Rmd", "# Main {#sec:main}\n\nThe answer is `r 6 * 7`; see Section \\@ref(sec:app).\n")
    write(dir .. "/2-appendix.Rmd", "# Appendix {#sec:app}\n\nOnly in the appendix.\n")
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex" }')
    vim.cmd.edit(dir .. "/1-main.Rmd")
    assert.is_true(make(), why())
    local main = text_of(dir .. "/main.pdf")
    assert.truthy(main:find("The answer is 42; see Section 2", 1, true), main)
    assert.falsy(main:find("Only in the appendix", 1, true))
    assert.truthy(vim.uv.fs_stat(dir .. "/.build/0-index-labels.aux"))
    local tex = read(dir .. "/.build/main/main.tex")
    assert.falsy(tex:find("pandoc", 1, true) or tex:find("\\hypertarget", 1, true)) -- (knitrmini's clean LaTeX)
    assert.same({}, leftovers(dir))
    assert.is_true(run(export), why())
  end)
end)

describe("standalone figures", function()
  -- a manuscript including two figures (fig2 without its extension, with options), fig2 reading a
  -- file of its own (as R-made panels are)
  local function paper()
    local dir = vim.fn.tempname()
    write(dir .. "/paper.tex", table.concat({
      "\\documentclass{article}", "\\usepackage{graphicx}", "\\begin{document}", "Text.",
      "\\includegraphics{figs/fig1.pdf}", "\\includegraphics[width=2cm]{figs/fig2}", "\\end{document}", "",
    }, "\n"))
    write(dir .. "/figs/fig1.tex", "% !TeX program = pdflatex\n\\documentclass{standalone}\n\\begin{document}One\\end{document}\n")
    write(dir .. "/figs/fig2.tex", "\\documentclass{standalone}\n\\begin{document}\\input{fig2-data}\\end{document}\n")
    write(dir .. "/figs/fig2-data.tex", "Two\n")
    write(dir .. "/figs/other.tex", "\\documentclass{standalone}\n\\begin{document}Other\\end{document}\n")
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex" }')
    return dir
  end
  local function make(args)
    messages = {}
    return run(function(done) require("manuscript.build").run(args or {}, done) end)
  end
  local function made(path)
    local st = vim.uv.fs_stat(path)
    return st and st.mtime.sec + st.mtime.nsec / 1e9
  end

  it("are found from the manuscript, built before it, and again only when they (or what they read) change", function()
    if not job.has("latexmk") or not job.has("pdflatex") then
      return pending("needs latexmk and pdflatex")
    end
    local dir = paper()
    local figures = require("manuscript.figures")
    local p = project_.find(dir)
    assert.same({ "fig1", "fig2" }, vim.tbl_map(function(f) return f.name end, figures.find(p)))
    assert.equal("pdflatex", figures.engine(figures.find(p)[1], p))
    -- its engine: its magic comment, else its last build's, else pdfLaTeX (LuaLaTeX with fontspec)
    local fig = { tex = dir .. "/figs/engine.tex" }
    write(fig.tex, "\\documentclass{standalone}\n\\usepackage[T1]{fontenc}\n\\begin{document}x\\end{document}\n")
    p.options.latex = "lualatex"
    assert.equal("pdflatex", figures.engine(fig, p))
    write(dir .. "/figs/engine.log", "This is LuaHBTeX, Version 1.24.0 (TeX Live 2026)\n")
    assert.equal("lualatex", figures.engine(fig, p))
    os.remove(dir .. "/figs/engine.log")
    write(fig.tex, "\\documentclass{standalone}\n\\usepackage{fontspec}\n\\begin{document}x\\end{document}\n")
    assert.equal("lualatex", figures.engine(fig, p))
    write(fig.tex, "% !TeX program = xelatex\n\\documentclass{standalone}\n\\begin{document}x\\end{document}\n")
    assert.equal("xelatex", figures.engine(fig, p))
    os.remove(fig.tex)
    p.options.latex = "pdflatex"
    vim.cmd.edit(dir .. "/paper.tex")
    assert.is_true(make(), why())
    local one, two = made(dir .. "/figs/fig1.pdf"), made(dir .. "/figs/fig2.pdf")
    assert.truthy(one and two and vim.uv.fs_stat(dir .. "/paper.pdf"))
    assert.is_nil(vim.uv.fs_stat(dir .. "/figs/other.pdf")) -- (not included)
    vim.wait(20)
    assert.is_true(make(), why())
    assert.equal(one, made(dir .. "/figs/fig1.pdf")) -- (unchanged: not built again)
    assert.equal(two, made(dir .. "/figs/fig2.pdf"))
    vim.wait(20)
    write(dir .. "/figs/fig2-data.tex", "Two, changed\n")
    assert.is_true(make(), why())
    assert.equal(one, made(dir .. "/figs/fig1.pdf"))
    assert.truthy(made(dir .. "/figs/fig2.pdf") > two) -- (what it reads changed: built again)
    -- cleaned with the manuscript: their auxiliary files, not their PDFs
    assert.truthy(vim.uv.fs_stat(dir .. "/figs/fig1.aux"))
    require("manuscript.build").clean({}, true)
    assert.is_nil(vim.uv.fs_stat(dir .. "/figs/fig1.aux"))
    assert.truthy(vim.uv.fs_stat(dir .. "/figs/fig1.pdf"))
  end)

  it("are configured: none (false), or more (globs); a figure's LaTeX errors stop the build, at its line", function()
    if not job.has("latexmk") or not job.has("pdflatex") then
      return pending("needs latexmk and pdflatex")
    end
    local dir = paper()
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex", figures = { "figs/oth*.tex" } }')
    local figures = require("manuscript.figures")
    assert.same({ "fig1", "fig2", "other" }, vim.tbl_map(function(f) return f.name end, figures.find(project_.find(dir))))
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex", figures = false }')
    assert.same({}, figures.find(project_.find(dir)))
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex" }')
    write(dir .. "/figs/fig1.tex", "\\documentclass{standalone}\n\\begin{document}\n\\nocommand\n\\end{document}\n")
    vim.cmd.edit(dir .. "/paper.tex")
    assert.is_false(make())
    vim.wait(100)
    local items = vim.fn.getqflist()
    assert.equal(1, #items)
    assert.equal(dir .. "/figs/fig1.tex", vim.fs.normalize(vim.fn.fnamemodify(vim.fn.bufname(items[1].bufnr), ":p")))
    assert.equal(3, items[1].lnum)
    assert.truthy(vim.iter(messages):any(function(m) return tostring(m):find("figure fig1 has LaTeX errors", 1, true) end))
    -- its PDF made with errors isn't taken as up to date: tried again (fixed by what it reads, not its .tex)
    assert.is_true(require("manuscript.figures").stale(require("manuscript.figures").find(project_.find(dir))[1]))
    assert.is_false(make())
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
    assert.truthy(vim.uv.fs_stat(dir .. "/.build/paper/paper_v2.aux"))
    assert.is_false(make({ "../elsewhere.pdf" }))
    build.clean({}, true)
    assert.is_nil(vim.uv.fs_stat(dir .. "/.build"))
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
    assert.truthy(vim.uv.fs_stat(dir .. "/.build/1_index-labels.aux"))
    local main = read(dir .. "/.build/main/main.tex")
    assert.truthy(main:find("See Section~2: 42", 1, true)) -- (its reference to the appendix: numbered)
    assert.falsy(main:find("Only in the appendix", 1, true))
    assert.same({}, vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir)))
    assert.truthy(read(dir .. "/1_index.Rnw"):find("eval=FALSE>>=", 1, true))
    -- the whole again only when a file outside the part changed (its numbering): not for the part
    local function snapshot_time()
      local st = vim.uv.fs_stat(dir .. "/.build/1_index-labels.aux")
      return st.mtime.sec + st.mtime.nsec / 1e9
    end
    local before = snapshot_time()
    vim.wait(20)
    write(dir .. "/.manuscript.lua", "return { check_numbers = false }") -- (the rule before the build alone)
    write(dir .. "/2_main.Rnw", "% !TeX root = 1_index.Rnw\n\\section{Main}\nSee Section~\\ref{sec:app}: \\Sexpr{6 * 7}!\n")
    assert.is_true(make(), why())
    assert.equals(before, snapshot_time())
    os.remove(dir .. "/.manuscript.lua")
    vim.wait(20)
    write(dir .. "/3_appendix1.Rnw", "\\section{First}\n\\section{Appendix}\\label{sec:app}\nOnly in the appendix.\n")
    assert.is_true(make(), why())
    assert.truthy(snapshot_time() > before)
    assert.truthy(read(dir .. "/.build/main/main.tex"):find("See Section~3: 42!", 1, true))
    write(dir .. "/3_appendix1.Rnw", "\\section{Appendix}\\label{sec:app}\nOnly in the appendix.\n")
    write(dir .. "/2_main.Rnw", "% !TeX root = 1_index.Rnw\n\\section{Main}\nSee Section~\\ref{sec:app}: \\Sexpr{6 * 7}.\n")
    assert.is_true(make(), why())
    -- builds leave nothing beside the sources but their PDFs: the rest is in .build/
    local function beside(name)
      return vim.tbl_filter(function(n)
        return vim.startswith(n, name .. ".") and not n:match("%.pdf$") and not n:match("%.Rnw$")
      end, vim.fn.readdir(dir))
    end
    assert.same({}, beside("main"))
    assert.same({}, beside("1_index"))
    -- cleaned: a part's build alone, or all of them (and the labels of the whole); the PDFs stay
    local function aux(name)
      return vim.fn.glob(dir .. "/.build/*/" .. name .. ".*", true, true)
    end
    assert.truthy(#aux("main") > 0 and #aux("1_index") > 0)
    build.clean({ "main" }, true)
    assert.same({}, aux("main"))
    assert.truthy(#aux("1_index") > 0)
    assert.truthy(vim.uv.fs_stat(dir .. "/.build/1_index-labels.aux"))
    build.clean({}, true)
    assert.same({}, aux("1_index"))
    assert.is_nil(vim.uv.fs_stat(dir .. "/.build/1_index-labels.aux"))
    for _, kept in ipairs({ "main.pdf", "1_index.pdf" }) do
      assert.truthy(vim.uv.fs_stat(dir .. "/" .. kept), kept)
    end
    -- a part under another name: main_v2.pdf, main.pdf as it was; another part's name: no
    local main_pdf = read(dir .. "/main.pdf")
    write(dir .. "/2_main.Rnw", "% !TeX root = 1_index.Rnw\n\\section{Main}\nSee Section~\\ref{sec:app}: \\Sexpr{6*7}. Second version.\n")
    assert.is_true(make({ "main", "main_v2.pdf" }), table.concat(vim.tbl_map(tostring, messages), "\n"))
    assert.truthy(read(dir .. "/.build/main/main.tex"):find("Second version", 1, true))
    assert.truthy(read(dir .. "/.build/main/main.tex"):find("See Section~2: 42", 1, true))
    assert.truthy(vim.uv.fs_stat(dir .. "/main_v2.pdf"))
    assert.equal(main_pdf, read(dir .. "/main.pdf"))
    assert.is_false(make({ "main", "appendix1.pdf" }))
    assert.truthy(#aux("main_v2") > 0)
    build.clean({ "main_v2" }, true)
    assert.same({}, aux("main_v2"))
    assert.same({}, vim.tbl_filter(function(n) return n:match("^_manuscript") end, vim.fn.readdir(dir)))
  end)
end)


describe("variants", function()
  local variants = require("manuscript.variants")
  local build = require("manuscript.build")
  local function make(args)
    messages = {}
    return run(function(done) build.run(args or {}, done) end)
  end
  local function text_of(pdf)
    return vim.system({ "pdftotext", pdf, "-" }, { text = true }):wait().stdout or ""
  end
  -- a paper whose preamble guards its switches (built otherwise, they are off) and uses them
  local PAPER = table.concat({
    "\\documentclass{article}",
    "\\ifcsname ifanonymous\\endcsname\\else\\expandafter\\newif\\csname ifanonymous\\endcsname\\fi",
    "\\ifcsname ifsecret\\endcsname\\else\\expandafter\\newif\\csname ifsecret\\endcsname\\fi",
    "\\begin{document}",
    "\\ifanonymous Authors withheld.\\else By Ana Author.\\fi",
    "\\ifsecret The secret.\\fi",
    "Variant: [\\manuscriptvariant].",
    "\\end{document}",
  }, "\n")

  it("define every switch before the source: off, but for the variant's; its name", function()
    local project = { options = { variants = { geb = { anonymous = true, linenumbers = true, submit = {} } } } }
    local none = variants.pretex(project, nil)
    assert.truthy(none:find("\\newif\\ifanonymous", 1, true))
    assert.truthy(none:find("\\newif\\iffiguresatend", 1, true)) -- (a template's, in no variant)
    assert.falsy(none:find("true", 1, true))
    assert.truthy(none:find("\\def\\manuscriptvariant{}", 1, true))
    local geb = variants.pretex(project, "geb")
    assert.truthy(geb:find("\\newif\\ifanonymous\\anonymoustrue", 1, true))
    assert.truthy(geb:find("\\newif\\iflinenumbers\\linenumberstrue", 1, true))
    assert.falsy(geb:find("\\draftversiontrue", 1, true))
    assert.truthy(geb:find("\\def\\manuscriptvariant{geb}", 1, true))
    assert.same({ "anon", "draft", "geb", "review" }, variants.names(project))
    assert.has_error(function() variants.pretex(project, "nope") end)
    assert.has_error(function() variants.pretex({ options = { variants = { x = { ["line-numbers"] = true } } } }, "x") end)
  end)

  it("build beside the usual PDF, as <name>-<variant>.pdf; a manuscript's own; cleaned alone", function()
    if not job.has("latexmk") or not job.has("pdflatex") or not job.has("pdftotext") then
      return pending("needs latexmk, pdflatex and pdftotext")
    end
    local dir = vim.fn.tempname()
    write(dir .. "/paper.tex", PAPER)
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex", variants = { full = { anonymous = true, secret = true } } }')
    vim.cmd.edit(dir .. "/paper.tex")
    assert.is_true(make(), why())
    local usual = text_of(dir .. "/paper.pdf")
    assert.truthy(usual:find("By Ana Author.", 1, true), usual)
    assert.truthy(usual:find("Variant: [].", 1, true), usual)
    assert.is_true(make({ "anon" }), why())
    local anon = text_of(dir .. "/paper-anon.pdf")
    assert.truthy(anon:find("Authors withheld.", 1, true), anon)
    assert.falsy(anon:find("Ana Author", 1, true))
    assert.truthy(anon:find("Variant: [anon].", 1, true), anon)
    assert.truthy(text_of(dir .. "/paper.pdf"):find("By Ana Author.", 1, true)) -- (the usual one, as it was)
    assert.is_true(make({ "full" }), why())
    assert.truthy(text_of(dir .. "/paper-full.pdf"):find("The secret.", 1, true))
    -- nothing beside the sources but the PDFs
    assert.same({ ".build", ".manuscript.lua", "paper-anon.pdf", "paper-full.pdf", "paper.pdf", "paper.tex" }, vim.fn.sort(vim.fn.readdir(dir)))
    assert.equals("*", read(dir .. "/.build/.gitignore"):gsub("%s+$", ""))
    build.clean({ "paper-anon" }, true)
    assert.same({}, vim.fn.glob(dir .. "/.build/*/paper-anon.*", true, true))
    assert.truthy(#vim.fn.glob(dir .. "/.build/*/paper-full.*", true, true) > 0)
    assert.truthy(vim.uv.fs_stat(dir .. "/paper-anon.pdf"))
  end)
end)

describe("a submission", function()
  local submit = require("manuscript.submit")
  local function go(args)
    messages = {}
    return run(function(done) submit.run(args, done) end)
  end
  local function text_of(pdf)
    return vim.system({ "pdftotext", pdf, "-" }, { text = true }):wait().stdout or ""
  end
  -- a paper: its author block in \ifanonymous, a comment naming her, figures (two through a macro),
  -- two .bib files (an entry not cited), a local package, an appendix (\include), a title page
  local function paper()
    local dir = vim.fn.tempname()
    write(dir .. "/paper.tex", table.concat({
      "\\documentclass{article}", "\\usepackage{graphicx}", "\\usepackage[backend=biber]{biblatex}", "\\usepackage{mystyle}",
      "\\addbibresource{refs.bib}", "\\addbibresource{more.bib}",
      "\\ifcsname ifanonymous\\endcsname\\else\\expandafter\\newif\\csname ifanonymous\\endcsname\\fi",
      "\\title{A study}", "\\ifanonymous", "\\author{}", "\\else", "\\author{Ana Lopezgarcia\\thanks{ana.lopez@uni.example}}", "\\fi",
      "\\newcommand{\\panel}[1]{\\includegraphics[width=2cm]{panels/p_#1}}",
      "\\begin{document}", "\\maketitle", "% a note: ask Ana Lopezgarcia about it",
      "See Appendix~\\ref{sec:app} and \\textcite{smith2020}. \\mything.",
      "\\includegraphics[width=3cm]{figs/fig1}", "\\panel{a}\\panel{b}",
      "\\ifanonymous\\else We thank the Lopezgarcia lab.\\fi",
      "\\include{appendix}", "\\printbibliography", "\\end{document}",
    }, "\n"))
    write(dir .. "/appendix.tex", "\\section{Appendix}\\label{sec:app}\nOnly in the appendix; see \\cite{jones2019}.\n")
    write(dir .. "/mystyle.sty", "\\ProvidesPackage{mystyle}\n\\newcommand{\\mything}{The thing}\n")
    write(dir .. "/refs.bib", "@article{smith2020, author={Smith, J.}, title={One}, journal={J}, year={2020}}\n"
      .. "@article{unused2000, author={Nobody}, title={Unused}, journal={J}, year={2000}}\n")
    write(dir .. "/more.bib", "@article{jones2019, author={Jones, K.}, title={Two}, journal={J}, year={2019}}\n")
    write(dir .. "/title_page.tex", "\\documentclass{article}\n\\begin{document}\nTitle page: Ana Lopezgarcia.\n\\end{document}\n")
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex", identity = { "Lopezgarcia" } }')
    for _, f in ipairs({ "figs/fig1", "panels/p_a", "panels/p_b" }) do
      write(dir .. "/" .. f .. ".tex", "\\documentclass{standalone}\\begin{document}" .. vim.fs.basename(f):gsub("_", "") .. "\\end{document}\n")
      vim.system({ "pdflatex", "-interaction=batchmode", vim.fs.basename(f) .. ".tex" }, { cwd = vim.fs.dirname(dir .. "/" .. f) }):wait()
      os.remove(dir .. "/" .. f .. ".tex") -- (pictures, not standalone figures to build)
    end
    return dir
  end
  local function ready()
    return job.has("latexmk") and job.has("pdflatex") and job.has("biber") and job.has("pdftotext") and job.has("zip")
  end

  it("anonymous: no authors in its source or PDFs, only what it cites, its figures, its own package; compiles alone", function()
    if not ready() then
      return pending("needs latexmk, pdflatex, biber, pdftotext and zip")
    end
    local dir = paper()
    vim.cmd.edit(dir .. "/paper.tex")
    vim.fn.setqflist({}, " ", { title = "none", items = {} })
    assert.is_true(go({ "anon" }), why())
    local folder = dir .. "/submission/anon-" .. os.date("%Y-%m-%d")
    local src = read(folder .. "/latex/main.tex")
    assert.falsy(src:find("Lopezgarcia", 1, true), src)
    assert.falsy(src:find("ana.lopez", 1, true))
    assert.falsy(src:find("ask Ana", 1, true)) -- (the comment)
    assert.falsy(src:find("ifanonymous", 1, true))
    assert.truthy(src:find("See Appendix~1", 1, true)) -- (the appendix: its own PDF; its number kept)
    assert.truthy(src:find("{figures/fig1.pdf}", 1, true))
    assert.truthy(src:find("{figures/p_#1}", 1, true))
    assert.truthy(src:find("\\addbibresource{references.bib}", 1, true))
    assert.falsy(src:find("more.bib", 1, true))
    local refs = read(folder .. "/latex/references.bib")
    assert.truthy(refs:find("smith2020", 1, true))
    assert.falsy(refs:find("unused2000", 1, true) or refs:find("jones2019", 1, true)) -- (cited by the appendix only)
    for _, f in ipairs({ "latex/figures/fig1.pdf", "latex/figures/p_a.pdf", "latex/figures/p_b.pdf", "latex/mystyle.sty",
      "latex/main.bbl", "main.pdf", "Appendix_S1.pdf", "title_page.pdf", "anon-" .. os.date("%Y-%m-%d") .. "-latex.zip" }) do
      assert.truthy(vim.uv.fs_stat(folder .. "/" .. f), f)
    end
    assert.truthy(text_of(folder .. "/Appendix_S1.pdf"):find("Only in the appendix", 1, true))
    assert.truthy(text_of(folder .. "/title_page.pdf"):find("Ana Lopezgarcia", 1, true)) -- (named)
    assert.same({}, vim.fn.glob(dir .. "/*-anon.pdf", true, true)) -- (its PDFs: in the submission only)
    local pdf = text_of(folder .. "/main.pdf")
    assert.falsy(pdf:find("Lopezgarcia", 1, true), pdf)
    assert.truthy(pdf:find("The thing", 1, true))
    vim.wait(100)
    assert.equals("none", vim.fn.getqflist({ title = true }).title) -- (no trace of the authors)
    -- recorded: a diff with it, by its name
    assert.truthy(vim.iter(require("manuscript.snapshot").list(project_.find(dir .. "/paper.tex"))):find(function(s) return s.manifest.kind == "submission" end))
    -- a resubmission: the tracked changes since the last one, in it
    write(dir .. "/paper.tex", read(dir .. "/paper.tex"):gsub("and \\textcite", "and the revised \\textcite"))
    assert.is_true(go({ "anon" }), why())
    local again = dir .. "/submission/anon-" .. os.date("%Y-%m-%d") .. "-2"
    local changes = text_of(again .. "/changes_since_anon-" .. os.date("%Y-%m-%d") .. ".pdf")
    assert.truthy(changes:find("revised", 1, true), changes)
    assert.falsy(changes:find("Lopezgarcia", 1, true)) -- (anonymous too)
    -- a diff with it, by its name
    write(dir .. "/paper.tex", read(dir .. "/paper.tex"):gsub("See Appendix", "Now see Appendix"))
    assert.is_true(run(function(done) require("manuscript.diff").run({ "@anon" }, done) end), why())
    assert.truthy(read(dir .. "/.build/diff/anon-" .. os.date("%Y-%m-%d") .. "-2-vs-now.tex"):find("DIFadd{Now", 1, true))
  end)

  it("finds the authors where they are left; named: they stay", function()
    if not ready() then
      return pending("needs latexmk, pdflatex, biber, pdftotext and zip")
    end
    local dir = paper()
    write(dir .. "/paper.tex", read(dir .. "/paper.tex"):gsub("\\maketitle", "\\maketitle\nAs we (Lopezgarcia) showed."))
    vim.cmd.edit(dir .. "/paper.tex")
    assert.is_true(go({ "anon" }), why())
    vim.wait(100)
    assert.equals("manuscript submit: anonymity", vim.fn.getqflist({ title = true }).title)
    local items = vim.fn.getqflist()
    assert.truthy(vim.iter(items):any(function(i) return i.text:find("in the source", 1, true) end))
    assert.truthy(vim.iter(items):any(function(i) return i.text:find("main.pdf, its text", 1, true) end))
    assert.is_true(go({ "named" }), why())
    local src = read(dir .. "/submission/manuscript-named-" .. os.date("%Y-%m-%d") .. "/latex/main.tex")
    assert.truthy(src:find("\\author{Ana Lopezgarcia", 1, true))
    assert.truthy(src:find("We thank the Lopezgarcia lab.", 1, true))
  end)

  it("flat (a journal that takes no folders): the figures beside main.tex; under another name", function()
    if not ready() then
      return pending("needs latexmk, pdflatex, biber, pdftotext and zip")
    end
    local dir = paper()
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex", variants = { em = { submit = { flat = true, name = "paper" } } } }')
    vim.cmd.edit(dir .. "/paper.tex")
    assert.is_true(go({ "em" }), why())
    local folder = dir .. "/submission/em-" .. os.date("%Y-%m-%d")
    local src = read(folder .. "/latex/paper.tex")
    assert.truthy(src:find("{fig1.pdf}", 1, true), src)
    assert.truthy(src:find("{p_#1}", 1, true))
    assert.falsy(src:find("figures/", 1, true))
    for _, f in ipairs({ "latex/fig1.pdf", "latex/p_a.pdf", "latex/paper.bbl", "paper.pdf" }) do
      assert.truthy(vim.uv.fs_stat(folder .. "/" .. f), f)
    end
    assert.is_nil(vim.uv.fs_stat(folder .. "/latex/figures"))
  end)

  it("fails when its source doesn't compile on its own", function()
    if not ready() then
      return pending("needs latexmk, pdflatex, biber, pdftotext and zip")
    end
    local dir = paper()
    -- (a package only the manuscript's folder has, read from a path the bundle can't follow)
    vim.fn.mkdir(dir .. "/sty", "p")
    vim.uv.fs_rename(dir .. "/mystyle.sty", dir .. "/sty/mystyle.sty")
    write(dir .. "/paper.tex", read(dir .. "/paper.tex"):gsub("\\usepackage{mystyle}", "\\usepackage{sty/mystyle}"))
    vim.cmd.edit(dir .. "/paper.tex")
    assert.is_false(go({}))
    assert.truthy(vim.iter(messages):any(function(m) return tostring(m):find("doesn't compile on its own", 1, true) end), why())
  end)
end)

describe("a new manuscript", function()
  it("from each template: its root found from any of its files (not its title page), built, by parts", function()
    local new = require("manuscript.new")
    assert.same({ "jnw", "rmd", "rnw", "tex" }, vim.fn.sort(vim.tbl_keys(new.templates())))
    for _, kind in ipairs({ "rnw", "rmd", "tex", "jnw" }) do
      local dir = vim.fn.tempname()
      new.run({ kind, dir })
      local root = project_.root(dir)
      assert.truthy(root, kind)
      assert.equals(root, vim.api.nvim_buf_get_name(0)) -- (opened)
      for _, file in ipairs({ "00_preamble.tex", "01_metadata.tex", "title_page.tex" }) do
        local expected = file == "title_page.tex" and dir .. "/title_page.tex" or root
        assert.equals(expected, project_.root(dir .. "/" .. file), kind .. ": " .. file)
      end
      local project = project_.find(root)
      assert.equals(2, #project.parts, kind)
      assert.truthy(vim.uv.fs_stat(dir .. "/.manuscript.lua"))
      assert.is_nil(vim.uv.fs_stat(dir .. "/.git"))
    end
    -- not in a folder that has files
    local dir = vim.fn.tempname()
    write(dir .. "/mine.txt", "x")
    new.run({ "rnw", dir })
    assert.same({ "mine.txt" }, vim.fn.readdir(dir))
  end)
end)

describe("an archive", function()
  it("is what git tracks, as it is now, with the files of archive.include, but archive.exclude", function()
    if not job.has("git") or not job.has("zip") then
      return pending("needs git and zip")
    end
    local top = vim.fn.tempname()
    for _, f in ipairs({ "R/analysis.R", "data/raw.csv", "data/big.csv", "manuscript/paper.tex" }) do
      write(top .. "/" .. f, f:match("paper") and "\\documentclass{article}\n\\begin{document}x\\end{document}\n" or "x\n")
    end
    write(top .. "/results/fit.rds", "untracked result\n")
    vim.system({ "git", "init", "-q" }, { cwd = top }):wait()
    vim.system({ "git", "add", "R", "data", "manuscript" }, { cwd = top }):wait()
    vim.system({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x" }, { cwd = top }):wait()
    write(top .. "/R/analysis.R", "changed since\n")
    local archive = require("manuscript.archive")
    assert.same({ "R/analysis.R", "data/big.csv", "data/raw.csv", "manuscript/paper.tex", "results/fit.rds" },
      archive.files(top, { include = { "results" } }))
    assert.same({ "R/analysis.R", "data/raw.csv", "manuscript/paper.tex" }, archive.files(top, { exclude = { "data/big.csv" } }))
    write(top .. "/manuscript/.manuscript.lua", 'return { archive = { include = { "results/*.rds" } } }')
    vim.cmd.edit(top .. "/manuscript/paper.tex")
    assert.is_true(run(function(done) archive.run({}, done) end), why())
    local zip = top .. "/manuscript/submission/" .. vim.fs.basename(top) .. "-" .. os.date("%Y-%m-%d") .. ".zip"
    local listed = vim.system({ "unzip", "-Z1", zip }, { text = true }):wait().stdout
    assert.truthy(listed:find("results/fit.rds", 1, true), listed)
    assert.truthy(listed:find("R/analysis.R", 1, true))
    assert.equals("changed since\n", vim.system({ "unzip", "-p", zip, "R/analysis.R" }, { text = true }):wait().stdout)
  end)
end)

describe("a worker", function()
  it("that exits with status 3 (a package installed again) is started anew, and given the knit again", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    -- (a worker that exits 3 at its first request, the first time; then knits: writes the output)
    write(dir .. "/fake.sh", table.concat({
      "#!/bin/sh",
      'read -r line',
      'if [ ! -f started ]; then touch started; exit 3; fi',
      'out=$(printf "%s" "$line" | cut -f3)',
      'echo knitted > "$out"',
      'printf "  | a chunk\\n\\001done\\tok\\n"',
      "read -r line",
    }, "\n"))
    local project = { dir = dir, options = { julia = { "sh", dir .. "/fake.sh" } } }
    local lines = {}
    local ok, err = run(function(done)
      job.task(function()
        require("manuscript.worker").knit(project, dir .. "/in.jnw", dir .. "/out.tex", false, nil, function(l) lines[#lines + 1] = l end)
      end, done, "worker")
    end), why()
    assert.is_true(ok, err)
    assert.equals("knitted\n", read(dir .. "/out.tex"))
    assert.same({ "  | a chunk" }, lines)
    require("manuscript.worker").stop(dir)
  end)
end)

describe("LaTeX's errors, in the sources", function()
  local build = require("manuscript.build")
  local function place(log, tex, sources)
    local dir = vim.fn.tempname()
    write(dir .. "/x.log", log)
    write(dir .. "/x.tex", tex)
    local files = {}
    for name, text in pairs(sources) do
      write(dir .. "/" .. name, text)
      files[#files + 1] = dir .. "/" .. name
    end
    table.sort(files)
    local items = build.in_sources(build.errors(dir .. "/x.log", dir .. "/x.tex"), { files = files })
    return vim.tbl_map(function(i) return { vim.fs.basename(i.filename), i.lnum, i.text } end, items)
  end

  it("an unclosed brace (no line from TeX): where its argument starts; the fatal errors after it left out", function()
    local log = table.concat({ "Runaway argument?", "{oops ran faster, as \\textcite {huey1979} expected: wi\\ETC.",
      "! File ended while scanning use of \\textbf .", "<inserted text>", "! Emergency stop.",
      "!  ==> Fatal error occurred, no output PDF file produced!" }, "\n")
    local tex = "\\documentclass{article}\n\\begin{document}\nWarm \\textbf{oops ran faster, as \\textcite{huey1979} expected.\n"
    local got = place(log, tex, { ["a.tex"] = "\\documentclass{article}\n", ["main.Rnw"] = "Intro.\n\nWarm \\textbf{oops ran faster, as \\textcite{huey1979} expected.\n" })
    assert.same({ { "main.Rnw", 3, "File ended while scanning use of \\textbf: a } missing?" } }, got)
  end)

  it("an unclosed brace alone on its line (a blank line after it), or going on on the next line", function()
    local tex = "\\documentclass{article}\n"
    local log = "Runaway argument?\n{oops \\par Temperature sets the pace of ectotherms \\parencite {huey19\\ETC.\n"
      .. "! File ended while scanning use of \\textbf .\n"
    local got = place(log, tex, { ["main.Rnw"] = "Intro.\n\\textbf{oops\n\nTemperature sets the pace of ectotherms \\parencite{huey1979}.\n" })
    assert.same({ "main.Rnw", 2 }, { got[1][1], got[1][2] })
    log = "Runaway argument?\n{oops ran on Temperature sets the pace of ectotherms \\parencite {huey19\\ETC.\n"
      .. "! File ended while scanning use of \\textbf .\n"
    got = place(log, tex, { ["main.Rnw"] = "Intro.\nWarm \\textbf{oops ran on\nTemperature sets the pace of ectotherms.\n" })
    assert.same({ "main.Rnw", 2 }, { got[1][1], got[1][2] })
  end)

  it("a line with a \\Sexpr{} (its value in the .tex); a line like many others: by its neighbours", function()
    local log = "! Undefined control sequence.\nl.3 0.89$), with no \\oops\n\n! Undefined control sequence.\nl.7 \\end{center}\\oops\n"
    local tex = "A line.\nslope 0.051~m,\n0.89$), with no \\oops pattern\nmore\nB\nC\n\\end{center}\\oops\n"
    local main = "A line.\nslope \\Sexpr{round(b, 3)}~m,\n\\Sexpr{round(r, 2)}$), with no \\oops pattern\nmore\nB\nC\n\\end{center}\\oops\n"
    local got = place(log, tex, { ["a_pre.tex"] = "x\n\\end{center}\\oops\ny\n", ["main.Rnw"] = main })
    assert.same({ "main.Rnw", 3 }, { got[1][1], got[1][2] })
    assert.same({ "main.Rnw", 7 }, { got[2][1], got[2][2] }) -- (not the preamble's, alike but alone)
  end)

  it("\\begin{x} ended by \\end{document}: where it began; a line only in the .tex stays there", function()
    local log = "! LaTeX Error: Something's wrong--perhaps a missing \\item.\nl.4 \\begin{center}\n\n"
      .. "! LaTeX Error: \\begin{itemize} on input line 2 ended by \\end{document}.\nl.9 \\end{document}\n"
    local tex = "Text before it.\n\\begin{itemize}\n\\begin{figure}\n\\begin{center}\n\\includegraphics{x}\n"
    local got = place(log, tex, { ["main.Rnw"] = "Text before it.\n\\begin{itemize}\n<<plot>>=\nplot(1)\n@\n", ["pre.tex"] = "\\begin{center}\n" })
    assert.same({ "x.tex", 4 }, { got[1][1], got[1][2] }) -- (knitr's figure: in no source)
    assert.same({ "main.Rnw", 2 }, { got[2][1], got[2][2] })
  end)
end)

describe("the numbers of a part's references", function()
  local build = require("manuscript.build")
  local function make(args)
    messages = {}
    return run(function(done) build.run(args or {}, done) end)
  end
  local function text_of(pdf)
    return vim.system({ "pdftotext", pdf, "-" }, { text = true }):wait().stdout or ""
  end

  it("are checked after the part's build: a counter running on into another part, fixed at once", function()
    if not job.has("latexmk") or not job.has("pdflatex") or not job.has("pdftotext") then
      return pending("needs latexmk, pdflatex and pdftotext")
    end
    local dir = vim.fn.tempname()
    -- (a .tex paper: its own text is the part "main", the appendix an \include; equations run on)
    local root = table.concat({ "\\documentclass{article}", "\\begin{document}",
      "See Equation~\\ref{eq:app}.", "\\include{appendix1}", "\\end{document}", "" }, "\n")
    write(dir .. "/paper.tex", root)
    write(dir .. "/appendix1.tex", "\\section{Appendix}\n\\begin{equation}b\\label{eq:app}\\end{equation}\n")
    write(dir .. "/.manuscript.lua", 'return { latex = "pdflatex" }')
    vim.cmd.edit(dir .. "/paper.tex")
    assert.is_true(make({ "main" }), why())
    assert.truthy(text_of(dir .. "/main.pdf"):find("See Equation 1.", 1, true))
    -- an equation of its own before: the appendix's is 2 now, which no file's date tells
    vim.wait(20)
    write(dir .. "/paper.tex", root:gsub("See Equation", "\\begin{equation}a\\end{equation}\nSee Equation"))
    assert.is_true(make({ "main" }), why())
    local main = text_of(dir .. "/main.pdf")
    assert.truthy(main:find("See Equation 2.", 1, true), main)
    -- built again unchanged: the same numbers
    assert.is_true(make({ "main" }), why())
    assert.truthy(text_of(dir .. "/main.pdf"):find("See Equation 2.", 1, true))
  end)

  it("are not checked for a part that refers to nothing outside itself", function()
    local labels = require("manuscript.labels")
    assert.is_false((labels.refers_outside({ "\\label{a} See \\ref{a}; <<fig1, fig.cap='x'>>= @ \\ref{fig:fig1}" })))
    assert.is_true((labels.refers_outside({ "See \\ref{tab:data}." })))
    local own = { mine = true }
    local before = { mine = { num = "1", page = "1" }, other = { num = "2", page = "5" } }
    assert.is_false(labels.changed(before, { mine = { num = "9", page = "1" }, other = { num = "2", page = "5" } }, own, false))
    assert.is_true(labels.changed(before, { mine = { num = "1", page = "1" }, other = { num = "3", page = "5" } }, own, false))
    assert.is_false(labels.changed(before, { mine = { num = "1", page = "1" }, other = { num = "2", page = "6" } }, own, false))
    assert.is_true(labels.changed(before, { mine = { num = "1", page = "1" }, other = { num = "2", page = "6" } }, own, true))
  end)
end)
