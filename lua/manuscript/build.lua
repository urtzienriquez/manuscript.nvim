-- :Manuscript build [part|all|watch], :Manuscript clean [part|all]: the PDF of the manuscript, or of
-- one of its parts, as you would make it by hand (knitrmini::knit(..., engine = "lualatex")), in the
-- background. A part is knitted from a copy of the root with only its child chunk evaluated (see
-- knit.lua), into <part>.tex/.pdf beside the root; the whole into <root>.tex/.pdf. The auxiliary
-- files stay there, so latexmk only reruns what it must: one LaTeX pass for a text edit.
--
-- A full build keeps the labels of the whole (<root>-labels.aux, knitrmini's snapshot), with
-- which a part's references to the others get their numbers; a part built before any full build
-- makes one first.
local job = require("manuscript.job")
local project_ = require("manuscript.project")
local knit = require("manuscript.knit")
local M = {}

local running, again = false, nil -- (a build asked for while another runs: made when it ends,
-- once; two builds at once would write the same auxiliary files)
local opened = {} -- (the PDFs opened once: viewers reload them by themselves)

local function base(path)
  return (vim.fs.basename(path):gsub("%.[^.]+$", ""))
end

-- The part a file is in: { name, file }, or nil (the root, or another file: the whole).
function M.part_of(project, file)
  file = file and vim.fs.normalize(file)
  for _, part in ipairs(project.parts) do
    if part.file == file and part.file ~= project.root then
      return part
    end
  end
end

-- LaTeX's errors in a log ("! message", then "l.<line> ..."), as quickfix items in the .tex.
function M.errors(log, tex)
  local items, current = {}, nil
  for line in (project_.read(log) or ""):gmatch("[^\n]*") do
    local message = line:match("^! (.+)")
    if message then
      current = { filename = tex, lnum = 1, text = message, type = "E" }
      items[#items + 1] = current
    elseif current and line:match("^l%.%d+") then -- ("l.52 ...the text up to the error")
      current.lnum, current.context = tonumber(line:match("^l%.(%d+)")), line:match("^l%.%d+ (.*)$")
      current = nil
    end
  end
  return items
end

-- The errors at their line in the sources, where it is there as it is in the .tex (most lines
-- are: knitting changes only chunks and \Sexpr{}); else in the .tex.
function M.in_sources(items, project)
  local files = { project.root }
  for _, part in ipairs(project.parts) do
    files[#files + 1] = part.file
  end
  local cache = {}
  local function lines(path)
    cache[path] = cache[path] or vim.split(project_.read(path) or "", "\n", { plain = true })
    return cache[path]
  end
  for _, item in ipairs(items) do
    local text = vim.trim(lines(item.filename)[item.lnum] or "")
    -- (or the text just before the error, if the line changed when knitted: a \Sexpr{} in it)
    local context = vim.trim((item.context or ""):gsub("^%.%.%.", "")):sub(-30)
    item.context = nil
    local tests = {}
    if #text >= 8 then -- (the same line first)
      tests[#tests + 1] = function(line) return vim.trim(line) == text end
    end
    if #context >= 12 then
      tests[#tests + 1] = function(line) return line:find(context, 1, true) ~= nil end
    end
    for _, test in ipairs(tests) do
      for _, file in ipairs(files) do
        for n, line in ipairs(lines(file)) do
          if test(line) then
            item.text = ("%s (%s:%d)"):format(item.text, vim.fs.basename(item.filename), item.lnum)
            item.filename, item.lnum = file, n
            goto found
          end
        end
      end
    end
    ::found::
  end
  return items
end

local function show(items, title)
  vim.schedule(function()
    local current = vim.fn.getqflist({ title = true }).title
    if #items > 0 then
      vim.fn.setqflist({}, " ", { title = title, items = items })
      vim.cmd("botright copen")
      vim.cmd("wincmd p")
    elseif current:find("^manuscript build") then -- (its errors are gone)
      vim.fn.setqflist({}, "r", { title = title, items = {} })
      vim.cmd("cclose")
    end
  end)
end

local compile
-- [root:name] = how long its last 5 builds took (s), for the progress; kept in the cache
local took
M.times = vim.fs.joinpath(vim.fn.stdpath("cache"), "manuscript", "build-times.json")

-- Knits (and compiles) `name`'s copy of the root: only `part`'s child, or all if nil. `label`: what
-- it is, in the progress message (nil: the build itself).
local function make(project, name, part, label)
  local key, started = project.root .. ":" .. name, vim.uv.hrtime()
  if not took then
    local ok, saved = pcall(vim.json.decode, project_.read(M.times) or "")
    took = ok and type(saved) == "table" and saved or {}
  end
  local times = took[key] or {}
  local sorted = vim.fn.sort(vim.deepcopy(times), "f")
  job.estimate(sorted[math.floor(#sorted / 2) + 1]) -- (their median: an unchanged build, or the first, aside)
  local out = compile(project, name, part, label)
  table.insert(times, (vim.uv.hrtime() - started) / 1e9)
  took[key] = vim.list_slice(times, math.max(#times - 4, 1))
  for k in pairs(took) do -- (only of manuscripts still there)
    if not vim.uv.fs_stat((k:gsub(":[^:]*$", ""))) then
      took[k] = nil
    end
  end
  vim.fn.mkdir(vim.fs.dirname(M.times), "p")
  pcall(vim.fn.writefile, { vim.json.encode(took) }, M.times)
  job.estimate(nil)
  return out
end

function compile(project, name, part, label)
  local dir, opts = project.dir, project.options
  local function say(step)
    job.say(label and label .. ": " .. step or step)
  end
  local out = name .. ".tex"
  if not project.rnw then -- (a .tex manuscript: just LaTeX)
    out = vim.fs.basename(project.root)
  else
    local copy = "_manuscript-" .. name .. ".Rnw"
    local f = assert(io.open(vim.fs.joinpath(dir, copy), "w"))
    f:write(knit.root_for(project_.read(project.root), part and part.file, dir))
    f:close()
    local snapshot = vim.fs.joinpath(dir, base(project.root) .. "-labels.aux")
    if part and vim.uv.fs_stat(snapshot) then -- (the labels of the whole, for its references)
      vim.uv.fs_copyfile(snapshot, vim.fs.joinpath(dir, "_manuscript-" .. name .. "-labels.aux"))
    end
    local expr = (opts.knit or "knitrmini") == "knitrmini" -- (not quiet: its chunks, and LaTeX, for the progress)
      and ("knitrmini::knit(%q, output = %q, engine = %q, quiet = FALSE)"):format(copy, out, opts.latex)
      or ("knitr::knit(%q, output = %q, quiet = TRUE)"):format(copy, out)
    say("knitting")
    local r = job.run({ "Rscript", "-e", expr }, { cwd = dir, line = function(line)
      local chunk = line:match("^%s*| (%S+)")
      if chunk and chunk ~= "inline" then
        say(("knitting (%s)"):format(chunk))
      elseif line:match("^%s*latexmk %(") then
        say("LaTeX")
      end
    end })
    if not vim.uv.fs_stat(vim.fs.joinpath(dir, out)) or (r.code ~= 0 and not (r.stderr or ""):find("PDF not produced", 1, true)) then
      knit.clean(dir)
      job.fail(("knitting %s failed:\n%s"):format(name, job.tail(r)))
    end
    if not part then -- (a full build: its labels, for the parts)
      local written = vim.fs.joinpath(dir, "_manuscript-" .. name .. "-labels.aux")
      if vim.uv.fs_stat(written) then
        os.rename(written, snapshot)
      end
    end
    knit.clean(dir)
    if (opts.knit or "knitrmini") == "knitrmini" then
      return out
    end
  end
  -- (knitr, or a .tex manuscript: latexmk here; under its own name, if not the root's)
  say("LaTeX")
  local cmd = { "latexmk", require("manuscript").latexmk_flag(opts.latex), "-interaction=nonstopmode", out }
  if base(out) ~= name then
    table.insert(cmd, #cmd, "-jobname=" .. name)
  end
  job.run(cmd, { cwd = dir })
  return out
end

M.make = make

-- :Manuscript build [part|all] [name.pdf]: the part of the current file (or the whole); with a
-- name.pdf, built under that name (name.tex, name.pdf...; the usual ones stay as they were).
-- on_done(ok).
function M.run(args, on_done)
  local as
  args = vim.tbl_filter(function(arg)
    as = arg:match("%.pdf$") and arg or as
    return not arg:match("%.pdf$")
  end, args or {})
  if args[1] == "watch" then
    return M.watch()
  end
  local file = vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) or nil
  if running then
    again = { vim.list_extend({ as }, args), on_done, file }
    return vim.notify("[manuscript] A build is running: this one follows it")
  end
  running = true
  job.task(function()
    local project = project_.find(file)
    local part
    if args[1] and args[1] ~= "all" then
      part = vim.iter(project.parts):find(function(p) return p.name == args[1] end)
        or job.fail(("no part %s (the parts: %s)"):format(args[1], table.concat(vim.tbl_map(function(p) return p.name end, project.parts), ", ")))
    elseif not args[1] then
      part = M.part_of(project, file)
    end
    if #project.parts < 2 then
      part = nil
    end
    if project.rnw then
      job.need("Rscript", "to knit .Rnw files")
    end
    job.need("latexmk", "to build the PDF")
    local whole = base(project.root)
    local name = part and part.name or whole
    if as then
      local own = as:gsub("%.pdf$", "")
      local taken = vim.tbl_map(function(p) return p.name end, project.parts)
      taken[#taken + 1] = whole
      if own:find("/") or own:match("^_manuscript") or own == "" then
        job.fail(as .. ": a name only (the PDF is made beside the root, where its figures are)")
      elseif own ~= name and vim.tbl_contains(taken, own) then
        job.fail(("%s: that's %s's PDF (the parts: %s)"):format(as, own, table.concat(taken, ", ")))
      end
      name = own
    end
    job.title("build " .. name)
    if part and project.rnw and not vim.uv.fs_stat(vim.fs.joinpath(project.dir, whole .. "-labels.aux")) then
      make(project, whole, nil, "the whole first (for the numbers of references)")
    end
    local out = make(project, name, part)
    local pdf = vim.fs.joinpath(project.dir, name .. ".pdf")
    local found = M.in_sources(M.errors(vim.fs.joinpath(project.dir, name .. ".log"), vim.fs.joinpath(project.dir, out)), project)
    show(found, "manuscript build: " .. name)
    if #found > 0 then
      job.fail(("%s has LaTeX errors: %d in the quickfix list"):format(name, #found))
    elseif not vim.uv.fs_stat(pdf) then
      job.fail(name .. ": no PDF made")
    end
    job.say(vim.fn.fnamemodify(pdf, ":~:.") .. " ready")
    if not opened[pdf] then
      opened[pdf] = true
      vim.schedule(function() vim.ui.open(pdf) end)
    end
  end, function(ok)
    running = false
    if on_done then
      on_done(ok)
    end
    if again then -- (asked for meanwhile)
      local next_args, next_done, next_file = unpack(again)
      again = nil
      local buf = next_file and vim.fn.bufnr(next_file)
      vim.api.nvim_buf_call(buf and buf > 0 and buf or 0, function() M.run(next_args, next_done) end)
    end
  end, "build")
end

-- :Manuscript build watch: build when a file of the manuscript is written (again: off).
local watching
function M.watch(on, quiet)
  if on == nil then
    on = not watching
  end
  if watching then
    pcall(vim.api.nvim_del_augroup_by_id, watching)
    watching = nil
  end
  if on then
    local timer = assert(vim.uv.new_timer())
    watching = vim.api.nvim_create_augroup("manuscript_build_watch", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = watching,
      pattern = { "*.Rnw", "*.rnw", "*.tex", "*.bib" },
      callback = function(ev)
        if vim.fs.basename(ev.file):match("^_manuscript") then
          return
        end
        local ok = pcall(project_.root, ev.file)
        if ok then
          timer:stop()
          timer:start(300, 0, vim.schedule_wrap(function() M.run({}) end))
        end
      end,
    })
  end
  if not quiet then
    vim.notify("[manuscript] Building on save: " .. (on and "on" or "off"))
  end
end

-- The names the manuscript was built under besides its parts' and the whole's (:Manuscript build
-- name.pdf): those with latexmk's files whose .tex has the preamble of the whole's or a part's (an
-- .Rnw manuscript), or whose source is the root (a .tex one, built with -jobname).
local function other_builds(project, names)
  local function preamble(path)
    local text = project_.read(path)
    return text and text:match("^(.-)\\begin{document}")
  end
  local ours = {}
  for _, name in ipairs(names) do
    local p = preamble(vim.fs.joinpath(project.dir, name .. ".tex"))
    if p then
      ours[p] = true
    end
  end
  local found = {}
  for file in vim.fs.dir(project.dir) do
    local name = file:match("^(.+)%.fdb_latexmk$")
    if name and not name:match("^_manuscript") and not vim.tbl_contains(names, name) then
      local p = project.rnw and preamble(vim.fs.joinpath(project.dir, name .. ".tex"))
      local fdb = not project.rnw and project_.read(vim.fs.joinpath(project.dir, file)) or ""
      if p and ours[p] or fdb:find('"' .. vim.fs.basename(project.root) .. '"', 1, true) then
        found[#found + 1] = name
      end
    end
  end
  table.sort(found)
  return found
end

-- :Manuscript clean [part|name|all]: the auxiliary files of the builds: of every build of the
-- manuscript (the whole, each part, and under other names) and the labels of the whole, or of one
-- build's. The knitted .tex and the PDF stay.
function M.clean(args, quiet)
  args = args or {}
  local ok, project = pcall(project_.find)
  if not ok then
    return vim.notify("[manuscript] " .. (type(project) == "table" and project.msg or tostring(project)), vim.log.levels.ERROR)
  end
  local whole = base(project.root)
  local names
  local usual = { whole }
  for _, part in ipairs(#project.parts > 1 and project.parts or {}) do
    usual[#usual + 1] = part.name
  end
  if args[1] and args[1] ~= "all" then
    local part = vim.iter(project.parts):find(function(p) return p.name == args[1] end)
    if part then
      names = { #project.parts > 1 and part.name or whole }
    elseif vim.tbl_contains(other_builds(project, usual), args[1]) then
      names = { args[1] }
    else
      return vim.notify("[manuscript] No part or build " .. args[1], vim.log.levels.ERROR)
    end
  else
    names = vim.list_extend(vim.deepcopy(usual), other_builds(project, usual))
  end
  local cleaned = {}
  local function remove(name)
    if os.remove(vim.fs.joinpath(project.dir, name)) then
      cleaned[#cleaned + 1] = name
    end
  end
  for _, name in ipairs(names) do
    if vim.uv.fs_stat(vim.fs.joinpath(project.dir, name .. ".fdb_latexmk")) then
      local tex = vim.uv.fs_stat(vim.fs.joinpath(project.dir, name .. ".tex")) and { name .. ".tex" }
        or { "-jobname=" .. name, vim.fs.basename(project.root) } -- (a .tex manuscript's, under another name)
      vim.system(vim.list_extend({ "latexmk", "-c" }, tex), { cwd = project.dir }):wait()
      cleaned[#cleaned + 1] = name .. ".*"
    end
    remove(name .. ".synctex.gz") -- (latexmk -c leaves it)
    remove(name .. "-tikzDictionary")
  end
  if not args[1] or args[1] == "all" then
    remove(whole .. "-labels.aux") -- (the next part's build makes the whole first)
  end
  if not quiet then
    vim.notify("[manuscript] " .. (#cleaned > 0 and "Cleaned: " .. table.concat(cleaned, ", ") or "Nothing to clean"))
  end
  return cleaned
end

return M
