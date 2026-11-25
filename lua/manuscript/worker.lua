-- The workers: one hidden process per manuscript's folder and language, started at its first knit
-- and kept, so that the language and the packages a document loads start once (later builds take
-- a fraction of a second):
--   julia   `julia --project=@. -e 'using Knit; Knit.serve()'` (the option `julia`: the command)
--   r       `Rscript -e 'knitrmini::serve()'` (the option `r_worker = false`: R started each time)
-- Each knit is a line it reads (`knit<TAB>input<TAB>output<TAB>compile<TAB>engine`); it prints the
-- knit's progress, then `\x01done<TAB>ok` (or `error<TAB>message`). A worker that exits with status
-- 3 (a package it loaded was installed again, or changed) is started anew, and given the knit
-- again. Stopped when Nvim exits; started again if it dies.
local job = require("manuscript.job")
local M = {}

-- Where knitrmini puts chunks' figures by default (relative to the document): out of its folder.
M.FIG_PATH = ".build/figure/"

local workers = {} -- [lang .. ":" .. dir] = { process, request = { line, on_line, done }, rest, stderr }

local function command(project, lang)
  if lang == "r" then
    return { "Rscript", "-e", "knitrmini::serve()" }
  end
  local julia = project.options.julia or { "julia" }
  julia = type(julia) == "string" and { julia } or vim.deepcopy(julia)
  return vim.list_extend(julia, { "--project=@.", "--startup-file=no", "-e", "using Knit; Knit.serve()" })
end

-- Why a worker exited, from its stderr (the end of it): what to do when its package is missing or
-- too old. lang: "julia" (default) or "r".
function M.reason(code, stderr, lang)
  if stderr:find("`serve` not defined", 1, true) then
    return "the Knit.jl Julia loads is too old (it has no Knit.serve()): update it, in Julia's"
      .. " default environment (or the document's): ] add https://github.com/urtzienriquez/Knit.jl"
  elseif stderr:find("Package Knit not found", 1, true) then
    return "Knit.jl isn't installed in Julia's default environment (or the document's):"
      .. " ] add https://github.com/urtzienriquez/Knit.jl"
  elseif stderr:find("'serve' is not an exported object", 1, true) then
    return "the knitrmini R loads is too old (it has no serve()): update it"
  elseif stderr:find("there is no package called .knitrmini.") then
    return "knitrmini isn't installed (in the R this manuscript's folder starts)"
  end
  local err = stderr:match("(ERROR:.-)\nStacktrace:") or stderr:match("(ERROR:.*)$")
    or stderr:match("(Error.*)$") or stderr
  return ("%s exited (%d): %s"):format(lang == "r" and "R" or "Julia", code or -1, vim.trim(err))
end

local start
local function send(w, request)
  w.request = request
  w.process:write(request.line)
end

function start(project, lang)
  local key = lang .. ":" .. project.dir
  local w = { rest = "", stderr = "" }
  local function line(text) -- (a whole line of its output)
    local request = w.request
    if not request then
      return
    end
    local status, message = text:match("^\1done\t(%a+)\t?(.*)$")
    if status then
      w.request = nil
      request.done(status, message)
    elseif request.on_line then
      request.on_line(text)
    end
  end
  w.process = vim.system(command(project, lang), {
    cwd = project.dir,
    env = lang == "r" and { KNITRMINI_FIG_PATH = M.FIG_PATH } or nil,
    stdin = true,
    text = true,
    stdout = function(_, data)
      if data then
        w.rest = w.rest .. data
        for l in w.rest:gmatch("([^\n]*)\n") do
          vim.schedule(function() line(l) end)
        end
        w.rest = w.rest:match("[^\n]*$")
      end
    end,
    stderr = function(_, data)
      if data then -- (its warnings and errors: the end, for a message)
        w.stderr = (w.stderr .. data):sub(-4000)
      end
    end,
  }, function(r)
    vim.schedule(function()
      if workers[key] == w then
        workers[key] = nil
      end
      local request = w.request
      w.request = nil
      if request and r.code == 3 and not request.again then -- (stale: a new one, the knit again)
        request.again = true
        local fresh = start(project, lang)
        send(fresh, request)
      elseif request then -- (it died during a knit)
        request.done("error", M.reason(r.code, w.stderr, lang))
      end
    end)
  end)
  workers[key] = w
  return w
end

-- In a task: knits `input` into `output` in the project's worker of `lang` ("julia", default, or
-- "r"), started if needed; compile: also builds the PDF. on_line: each line of its progress.
-- Fails on an error.
function M.knit(project, input, output, compile, engine, on_line, lang)
  lang = lang or "julia"
  job.need(lang == "r" and "Rscript" or "julia", "to knit " .. vim.fs.basename(input))
  local w = workers[lang .. ":" .. project.dir] or start(project, lang)
  local co = coroutine.running()
  send(w, {
    line = table.concat({ "knit", input, output, compile and "1" or "0", engine or "" }, "\t") .. "\n",
    on_line = on_line,
    done = function(status, message) coroutine.resume(co, status, message) end,
  })
  local status, message = coroutine.yield()
  if status ~= "ok" then
    job.fail(("knitting %s failed: %s"):format(vim.fs.basename(input), message ~= "" and message or vim.trim(w.stderr)))
  end
  if not vim.uv.fs_stat(output) and not vim.uv.fs_stat(vim.fs.joinpath(project.dir, output)) then
    job.fail(("knitting %s made no %s"):format(vim.fs.basename(input), vim.fs.basename(output)))
  end
end

-- Stops the workers (all, or a folder's).
function M.stop(dir)
  for key, w in pairs(workers) do
    if not dir or key:sub(-#dir - 1) == ":" .. dir then
      workers[key] = nil
      pcall(function() w.process:write("quit\n") end)
      pcall(function() w.process:kill(15) end)
    end
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("manuscript_worker", { clear = true }),
  callback = function() M.stop() end,
})

return M
