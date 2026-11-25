-- :Manuscript build [part|all|watch], :Manuscript clean [part|all]: the PDF of the manuscript, or of
-- one of its parts, as you would make it by hand (knitrmini::knit(..., engine = "lualatex")), in the
-- background. A part is knitted from a copy of the root with only its child chunk evaluated (see
-- knit.lua), into <part>.tex/.pdf beside the root; the whole into <root>.tex/.pdf. The auxiliary
-- files stay there, so latexmk only reruns what it must: one LaTeX pass for a text edit.
--
-- An .Rmd is rendered into its .tex, then built by latexmk; a .tex root's part is a copy of the
-- root without the other parts, built in the cache. Standalone figures it includes are built first
-- (see figures.lua).
--
-- A full build keeps the labels of the whole (knitrmini's snapshot, <root>-labels.aux; else the
-- whole's .aux, see labels.lua), with which a part's references to the others get their numbers;
-- a part built before any full build makes one first.
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

-- The part a file is in: { name, file }, or nil (the root, or another file: the whole). A part's
-- file or one it includes; a file the root includes, outside the parts: the root's own part (a .tex
-- root's "main"), if it has one.
function M.part_of(project, file)
  file = file and vim.fs.normalize(file)
  if not file or file == project.root then
    return nil
  end
  local own
  for _, part in ipairs(project.parts) do
    if part.file == project.root then
      own = part
    elseif part.file == file or vim.tbl_contains(project_.files(part.file, project.dir), file) then
      return part
    end
  end
  return own and vim.tbl_contains(project.files, file) and own or nil
end

-- LaTeX's errors in a log ("! message", then "l.<line> ..."), as quickfix items in the .tex. An
-- error TeX gives no line for (an unclosed brace: "File ended while scanning use of \textbf") has
-- the start of the runaway argument instead, from the line after "Runaway argument?": where to
-- find it (see M.in_sources). "\begin{x} on input line N ended by ...": at line N, where it began.
-- "Emergency stop" and the fatal error after it say nothing more: left out, when there is another.
function M.errors(log, tex)
  local items, noise, current, runaway, after_runaway = {}, {}, nil, nil, false
  for _, line in ipairs(vim.split(project_.read(log) or "", "\n", { plain = true })) do
    local message = line:match("^! (.+)")
    if after_runaway then
      runaway, after_runaway = (line:gsub("\\ETC%.$", "")), false
    elseif line == "Runaway argument?" then
      after_runaway = true
    elseif message then
      current = { filename = tex, lnum = 1, text = message, type = "E" }
      if message:match("^Emergency stop") or message:match("==> Fatal error") then
        noise[#noise + 1] = current
      else
        items[#items + 1] = current
        if runaway then -- (a } missing: no line, but where its argument starts)
          current.start = (message:match("use of (\\%a+)") or "") .. runaway
          current.text = message:gsub("%s*%.$", "") .. ": a } missing?"
          runaway = nil
        else
          current.unplaced = true -- (until its l.<line>)
        end
      end
    elseif current and line:match("^l%.%d+") then -- ("l.52 ...the text up to the error")
      current.lnum, current.context = tonumber(line:match("^l%.(%d+)")), line:match("^l%.%d+ (.*)$")
      current.unplaced = nil
      local begun = current.text:match("on input line (%d+)") -- (\begin{x} ... ended by: where it began)
      if begun then
        current.lnum, current.context = tonumber(begun), nil
      end
      current = nil
    end
  end
  return #items > 0 and items or noise
end

-- Whether a source line is this knitted line: the same, but for what knitting writes in place of
-- its \Sexpr{}s (`r ` in an .Rmd), which may be anything.
local function alike(source, knitted)
  source, knitted = vim.trim(source), vim.trim(knitted)
  if source == knitted then
    return true
  end
  local pieces, pos = {}, 1
  while true do
    local a, b = source:find("\\Sexpr%s*%b{}", pos)
    local c, d = source:find("`r[ #][^`]*`", pos)
    if c and (not a or c < a) then
      a, b = c, d
    end
    if not a then
      break
    end
    pieces[#pieces + 1] = vim.pesc(source:sub(pos, a - 1))
    pos = b + 1
  end
  if #pieces == 0 then
    return false
  end
  pieces[#pieces + 1] = vim.pesc(source:sub(pos))
  return knitted:match("^" .. table.concat(pieces, ".-") .. "$") ~= nil
end
M.alike = alike

-- Text as TeX prints it and as it is written, made comparable: no space after a control word
-- ("\textcite {x}"), spaces as one.
local function comparable(text)
  return (text:gsub("(\\%a+)%s+", "%1"):gsub("%s+", " "))
end

-- The errors at their line in the sources (in order, the first way that finds it):
--   the source line that is the .tex's (but for a \Sexpr{}'s value), with most of its neighbours
--   the same too (a line such as \end{center} is in many places);
--   the text just before the error (TeX's l.<line>), in the sources;
--   from the nearest line above it that is in the sources (see M.by_neighbour);
-- else in the .tex. One without a line (a runaway argument): where its argument starts.
function M.in_sources(items, project)
  local files = project.files
  local cache = {}
  local function lines(path)
    cache[path] = cache[path] or vim.split(project_.read(path) or "", "\n", { plain = true })
    return cache[path]
  end
  local function find(test, where) -- (the first line of `where` passing it: file, line)
    for _, file in ipairs(where) do
      for n, line in ipairs(lines(file)) do
        if test(line) then
          return file, n
        end
      end
    end
  end
  for _, item in ipairs(items) do
    local tex, n = item.filename, item.lnum
    local file, line
    if item.start then -- (a runaway argument's start: to its paragraph's end, \par, and 40 characters)
      local start = vim.trim(comparable((item.start:gsub("\\par%f[^%a].*$", ""))):sub(1, 40))
      -- (a line that has it, or that ends while it goes on: TeX joins lines with a space)
      local test = function(l)
        local cl = vim.trim(comparable(l))
        local at = #start >= 8 and cl:find(start:sub(1, 8), 1, true)
        if not at then
          return false
        end
        local rest = cl:sub(at)
        return vim.startswith(rest, start) or (#rest >= 8 and vim.startswith(start, rest))
      end
      file, line = find(test, files)
      if not file then
        file, line = find(test, { tex })
      end
    elseif not item.unplaced then
      local t = lines(tex)
      local this = vim.trim(t[n] or "")
      if #this >= 3 then -- (1. the same line, with the most neighbours the same)
        local best = -1
        for _, f in ipairs(files) do
          local fl = lines(f)
          for s, l in ipairs(fl) do
            if alike(l, this) then
              local score = 0
              for d = -3, 3 do
                local a, b = fl[s + d], t[n + d]
                if d ~= 0 and a and b and vim.trim(b) ~= "" and alike(a, b) then
                  score = score + 1
                end
              end
              if score > best then
                file, line, best = f, s, score
              end
            end
          end
        end
        if best == 0 and #this < 20 then -- (a short line, its neighbours unlike: not enough)
          file, line = nil, nil
        end
      end
      local context = vim.trim((item.context or ""):gsub("^%.%.%.", "")):sub(-30)
      if not file and #context >= 20 then -- (2. the text before the error: in one place only)
        local found = {}
        for _, f in ipairs(files) do
          for s, l in ipairs(lines(f)) do
            if l:find(context, 1, true) then
              found[#found + 1] = { f, s }
            end
          end
        end
        if #found == 1 then
          file, line = found[1][1], found[1][2]
        end
      end
      if not file then -- (3. from the line above it)
        file, line = M.by_neighbour(lines, files, tex, n)
      end
      if file then
        item.text = ("%s (%s:%d)"):format(item.text, vim.fs.basename(tex), n)
      end
    end
    if file then
      item.filename, item.lnum = file, line
    end
    item.context, item.start, item.unplaced = nil, nil, nil
  end
  return items
end

-- Where line `n` of the .tex is in the sources, from the nearest line above it that is there as it
-- is, once in the .tex and once in the sources (a line such as \begin{figure} could be anywhere),
-- the lines between them alike too: file, line; or nil (a line of a chunk's output, say).
function M.by_neighbour(lines, files, tex, n)
  local t = lines(tex)
  local function count(list, text)
    local c = 0
    for _, l in ipairs(list) do
      c = c + (vim.trim(l) == text and 1 or 0)
    end
    return c
  end
  for k = n - 1, math.max(1, n - 40), -1 do
    local above = vim.trim(t[k] or "")
    local in_sources = 0
    if #above >= 8 and count(t, above) == 1 then
      for _, file in ipairs(files) do
        in_sources = in_sources + count(lines(file), above)
      end
    end
    if in_sources == 1 then
      for _, file in ipairs(files) do
        local f = lines(file)
        for s, line in ipairs(f) do
          if vim.trim(line) == above and f[s + (n - k)] then
            local same = true
            for d = 1, n - k - 1 do
              if not alike(f[s + d] or "", t[k + d] or "") then
                same = false
                break
              end
            end
            if same then
              return file, s + (n - k)
            end
          end
        end
      end
    end
  end
end

function M.show(items, title)
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

-- Where a build's LaTeX runs: .build/<target>/ in the manuscript's folder (its .tex, latexmk's
-- files; the PDF is copied beside the root). .build/ keeps itself out of git.
function M.dir(project, target)
  local top = vim.fs.joinpath(project.dir, ".build")
  local dir = vim.fs.joinpath(top, target)
  vim.fn.mkdir(dir, "p")
  local ignore = vim.fs.joinpath(top, ".gitignore")
  if not vim.uv.fs_stat(ignore) then
    vim.fn.writefile({ "*" }, ignore)
  end
  return dir
end

-- Builds the whole (o.part nil) or a part: knitted (or rendered, or a .tex part's copy) into
-- .build/<target>/<target>.tex, then LaTeX, under the name o.job (default: the target's), with the
-- switches of o.variant. o.label: what it is, in the progress message (nil: the build itself);
-- o.inside: its PDF stays in .build/ (not copied beside the root).
-- Returns { tex, log } (what LaTeX read and wrote: for its errors).
local function make(project, o)
  o = o or {}
  local job_name = o.job or (o.part and o.part.name or project.name)
  local key, started = project.root .. ":" .. job_name, vim.uv.hrtime()
  if not took then
    local ok, saved = pcall(vim.json.decode, project_.read(M.times) or "")
    took = ok and type(saved) == "table" and saved or {}
  end
  local times = took[key] or {}
  local sorted = vim.fn.sort(vim.deepcopy(times), "f")
  job.estimate(sorted[math.floor(#sorted / 2) + 1]) -- (their median: an unchanged build, or the first, aside)
  local out = compile(project, o.part, o.label, job_name, o.variant, o.inside)
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

function compile(project, part, label, job_name, variant, inside)
  local dir = project.dir
  local labels = require("manuscript.labels")
  local function say(step)
    job.say(label and label .. ": " .. step or step)
  end
  local target = part and part.name or project.name
  local outdir = M.dir(project, target)
  local rel = ".build/" .. target -- (latexmk runs where the root is: its \input{}s, figures, .bib)
  local tex = rel .. "/" .. target .. ".tex"
  local snapshot = labels.snapshot(project) -- (the whole's labels: a part's references to the others)
  local how = knit.knitter(project)
  if project.kind == "tex" and part then -- (a copy of the root without the other parts)
    local copy = vim.fs.joinpath(dir, knit.tex_part(project, part, target))
    assert(vim.uv.fs_rename(copy, vim.fs.joinpath(dir, tex)))
  elseif project.kind == "tex" then
    tex = vim.fs.basename(project.root)
  elseif how == "rmarkdown" then -- (an .Rmd with an output format: rmarkdown's render)
    say("knitting")
    knit.render(project, target, part and part.file, vim.fs.joinpath(dir, tex), nil, function(line)
      local chunk = line:match("label:%s*(%S+)") or line:match("%[([%w_.-]+)%]%s*$")
      if line:match("pandoc") and line:match("%-%-to") then
        say("pandoc")
      elseif chunk then
        say(("knitting (%s)"):format(chunk))
      end
    end)
    if part then
      labels.resolve_file(vim.fs.joinpath(dir, tex), snapshot)
    end
  else -- knitted: knitrmini or knitr (.Rnw, .Rmd), Knit.jl (.jnw); LaTeX is run here, the same for all
    say("knitting")
    knit.knit(project, target, part and part.file, tex, false, nil, function(line)
      local chunk = line:match("^%s*| (%S+)")
      if chunk and chunk ~= "inline" then
        say(("knitting (%s)"):format(chunk))
      end
    end)
    if part and how == "knitr" then -- (knitrmini and Knit.jl resolve them from the snapshot)
      labels.resolve_file(vim.fs.joinpath(dir, tex), snapshot)
    end
  end
  say("LaTeX")
  job.run({ "latexmk", require("manuscript").latexmk_flag(knit.engine(project)), "-interaction=nonstopmode",
    "-outdir=" .. rel, "-jobname=" .. job_name, "-usepretex=" .. require("manuscript.variants").pretex(project, variant),
    tex }, { cwd = dir })
  local pdf, log = vim.fs.joinpath(outdir, job_name .. ".pdf"), vim.fs.joinpath(outdir, job_name .. ".log")
  if vim.uv.fs_stat(pdf) and not inside then
    vim.uv.fs_copyfile(pdf, vim.fs.joinpath(dir, job_name .. ".pdf"))
  end
  if not part and not variant and job_name == project.name and #M.errors(log, tex) == 0 then
    labels.write_snapshot(project, vim.fs.joinpath(outdir, job_name .. ".aux")) -- (a full build's, without errors)
  end
  return { tex = vim.fs.joinpath(dir, tex), log = log }
end

M.make = make

-- Whether the labels of the whole (the numbers of a part's references to the others) are up to
-- date for building `part`: the whole was built since any file outside that part changed (the root,
-- the preamble, another part: their numbering). Edits to the part itself don't matter: building it
-- doesn't make the whole again. Without `part`: whether the whole was built at all.
function M.has_labels(project, part)
  local st = vim.uv.fs_stat(require("manuscript.labels").snapshot(project))
  if not st or not part then
    return st ~= nil
  end
  local others, own = {}, {} -- (a part's files: but those of the other parts, as a .tex root's own part has them)
  for _, p in ipairs(project.parts) do
    if p ~= part then
      others[p.file] = true
      for _, f in ipairs(project_.files(p.file, project.dir)) do
        others[f] = true
      end
    end
  end
  for _, f in ipairs(vim.list_extend({ part.file }, project_.files(part.file, project.dir))) do
    own[f] = not others[f] or nil
  end
  for _, f in ipairs(project.files) do
    local fs = not own[f] and vim.uv.fs_stat(f)
    if fs and (fs.mtime.sec > st.mtime.sec or fs.mtime.sec == st.mtime.sec and fs.mtime.nsec > st.mtime.nsec) then
      return false
    end
  end
  return true
end

-- :Manuscript build [part|all] [variant] [name.pdf]: the part of the current file (or the whole);
-- with a variant (see variants.lua), its PDF is <part>-<variant>.pdf; with a name.pdf, built under
-- that name (the usual PDF stays as it was). on_done(ok).
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
    local variants = require("manuscript.variants")
    local variant
    args = vim.tbl_filter(function(arg)
      local named = variants.all(project)[arg] and not vim.iter(project.parts):find(function(p) return p.name == arg end)
      variant = named and arg or variant
      return not named
    end, args)
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
    if project.kind == "jnw" then
      job.need("julia", "to knit " .. vim.fs.basename(project.root))
    elseif project.kind ~= "tex" then
      job.need("Rscript", "to knit " .. vim.fs.basename(project.root))
    end
    job.need("latexmk", "to build the PDF")
    local whole = base(project.root)
    local name = (part and part.name or whole) .. (variant and "-" .. variant or "")
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
    require("manuscript.figures").update(project)
    local ok, made = pcall(function()
      if part and not M.has_labels(project, part) then
        make(project, { label = "the whole first (for the numbers of references)" })
      end
      return make(project, { part = part, job = name, variant = variant })
    end)
    if not ok then -- (its copies, knitr's figures: not left over)
      knit.clean(project.dir)
      error(made, 0)
    end
    local pdf = vim.fs.joinpath(project.dir, name .. ".pdf")
    local found = M.in_sources(M.errors(made.log, made.tex), project)
    knit.clean(project.dir) -- (a part's copy, knitr's figures: read for the errors, not needed now)
    M.show(found, "manuscript build: " .. name)
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
      pattern = { "*.Rnw", "*.rnw", "*.Rmd", "*.rmd", "*.jnw", "*.Jnw", "*.tex", "*.bib" },
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
      local p = project.kind ~= "tex" and preamble(vim.fs.joinpath(project.dir, name .. ".tex"))
      local fdb = project.kind == "tex" and project_.read(vim.fs.joinpath(project.dir, file)) or ""
      if p and ours[p] or fdb:find('"' .. vim.fs.basename(project.root) .. '"', 1, true) then
        found[#found + 1] = name
      end
    end
  end
  table.sort(found)
  return found
end

-- The builds in .build/ named `name` (a variant's, or under a name of its own): their files, in
-- whichever target's folder they are.
local function built_as(project, name)
  local found = {}
  local top = vim.fs.joinpath(project.dir, ".build")
  for target, kind in vim.fs.dir(top) do
    if kind == "directory" then
      for file in vim.fs.dir(vim.fs.joinpath(top, target)) do
        if file:sub(1, #name + 1) == name .. "." then
          found[#found + 1] = vim.fs.joinpath(top, target, file)
        end
      end
    end
  end
  return found
end

-- :Manuscript clean [part|name|all]: what the builds left: .build/ (all of it, with the labels of
-- the whole; a part's folder; or one build's files), and what builds made before .build/ existed
-- left beside the root. The PDFs stay.
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
    elseif #built_as(project, args[1]) > 0 then
      names = {}
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
    local cached = vim.fs.joinpath(require("manuscript.export").cache(project, "build"), name) -- (a .tex part's)
    if vim.uv.fs_stat(cached) then
      vim.fn.delete(cached, "rf")
      cleaned[#cleaned + 1] = name .. ".* (in the cache)"
    end
    for _, ext in ipairs({ ".synctex.gz", "-tikzDictionary", ".nav", ".snm", ".vrb", ".bbl", ".run.xml", "-blx.bib" }) do
      remove(name .. ext) -- (what latexmk -c leaves: SyncTeX's, beamer's, biblatex's...)
    end
  end
  local top = vim.fs.joinpath(project.dir, ".build")
  if not args[1] or args[1] == "all" then
    if vim.uv.fs_stat(top) then
      vim.fn.delete(top, "rf")
      cleaned[#cleaned + 1] = ".build/"
    end
  else
    local part = vim.iter(project.parts):find(function(p) return p.name == args[1] end)
    local folder = vim.fs.joinpath(top, part and #project.parts > 1 and part.name or whole)
    if part and vim.uv.fs_stat(folder) then
      vim.fn.delete(folder, "rf")
      cleaned[#cleaned + 1] = ".build/" .. vim.fs.basename(folder) .. "/"
    elseif not part then
      for _, file in ipairs(built_as(project, args[1])) do
        os.remove(file)
        cleaned[#cleaned + 1] = file:sub(#project.dir + 2)
      end
    end
  end
  if not args[1] or args[1] == "all" then
    remove(whole .. "-labels.aux") -- (the next part's build makes the whole first)
    vim.list_extend(cleaned, require("manuscript.figures").clean(project))
  end
  if not quiet then
    vim.notify("[manuscript] " .. (#cleaned > 0 and "Cleaned: " .. table.concat(cleaned, ", ") or "Nothing to clean"))
  end
  return cleaned
end

return M
