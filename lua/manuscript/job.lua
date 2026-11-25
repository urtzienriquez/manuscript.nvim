-- Long work (knitting, pandoc, latexmk) without blocking Neovim: a task is a coroutine, in which
-- run() waits for a command and fail() stops with a message for you.
local M = {}

-- A task's progress is one message, updated in place: its step, the time since it began, and how
-- far it is (if known). In Neovim 0.12+ a progress message (shown by ui2, fidget..., and by the
-- terminal as a progress bar); before, a notification per step.
local NATIVE = vim.fn.has("nvim-0.12") == 1
local tasks = setmetatable({}, { __mode = "k" }) -- [coroutine] = its progress
local bound -- (the progress of the task a callback of job.bind runs for)

local function current()
  if bound then
    return bound
  end
  local co, main = coroutine.running()
  return co and not main and tasks[co] or nil
end

-- (final: its last message, done or failed; in the message history if done)
local function show(p, final)
  if p.done and not final then -- (a tick of its timer, after its end)
    return
  end
  local secs = (vim.uv.hrtime() - p.started) / 1e9
  local text = secs < 1 and p.text or ("%s · %s"):format(p.text, secs < 10 and ("%.1f s"):format(secs) or ("%d s"):format(secs))
  if not NATIVE then
    if p.text ~= p.shown then
      p.shown = p.text
      vim.notify("[manuscript] " .. p.text)
    end
    return
  end
  local percent = p.percent
  if not percent and p.expect then -- (as long as before)
    percent = math.min(99, math.floor((vim.uv.hrtime() - p.since) / 1e9 / p.expect * 100))
  end
  if p.range and percent then -- (a phase's share of the whole; unknown stays unknown)
    percent = math.floor(p.range[1] + (p.range[2] - p.range[1]) * percent / 100)
  end
  p.id = vim.api.nvim_echo({ { text } }, final == true and p.status == "success", {
    id = p.id, kind = "progress", source = "manuscript", title = p.title,
    status = p.status, percent = p.status == "success" and 100 or percent,
  })
end

function M.fail(msg)
  error({ msg = msg }, 0)
end

-- Tasks run one after another: they share the manuscript's folder (its _manuscript-* files, which
-- each removes at its end). [1]: the one running; then those waiting for it, in order. Each:
-- { progress, start }.
local queue = {}

local function next_task()
  table.remove(queue, 1)
  if queue[1] then
    queue[1].start()
  end
end

-- Runs fn as a task (after those running), titled `title` in its progress message; on_done(ok) at
-- the end.
function M.task(fn, on_done, title)
  local p = { title = title or "manuscript", status = "running" }
  local co = coroutine.create(function()
    local ok, err = xpcall(fn, function(e)
      return type(e) == "table" and e.msg or debug.traceback(tostring(e), 2)
    end)
    p.done = true
    vim.schedule(function()
      if p.timer then
        p.timer:close()
      end
      if p.text then -- (its message: done, or failed)
        p.status, p.text = ok and "success" or "failed", ok and p.text or "failed"
        show(p, true)
      end
      if not ok then
        vim.notify("[manuscript] " .. err, vim.log.levels.ERROR)
      end
      next_task()
      if on_done then
        on_done(ok)
      end
    end)
  end)
  tasks[co] = p
  local function start()
    p.started = vim.uv.hrtime()
    local ok, err = coroutine.resume(co)
    if not ok then
      vim.notify("[manuscript] " .. tostring(err), vim.log.levels.ERROR)
      next_task()
    end
  end
  queue[#queue + 1] = { progress = p, start = start }
  if #queue == 1 then
    start()
  else
    p.started, p.text = vim.uv.hrtime(), "waiting for " .. queue[1].progress.title
    show(p)
  end
end

-- A command's result { code, stdout, stderr }: in a task, without blocking; else waiting.
-- opts.started(process): called with it (to stop it: process:kill(15)). opts.line(line): called
-- with each line of its output, as it comes.
function M.run(cmd, opts)
  opts = vim.tbl_extend("force", { text = true }, opts or {})
  local started, on_line = opts.started, opts.line
  opts.started, opts.line = nil, nil
  local out, rest = {}, ""
  if on_line then
    on_line = M.bind(on_line)
    opts.stdout = function(_, data)
      if data then
        out[#out + 1], rest = data, rest .. data
        for line in rest:gmatch("([^\n]*)\n") do
          vim.schedule(function() on_line(line) end)
        end
        rest = rest:match("[^\n]*$")
      end
    end
  end
  local function result(r)
    if on_line then
      r.stdout = table.concat(out)
    end
    return r
  end
  local co, main = coroutine.running()
  if not co or main then
    return result(vim.system(cmd, opts):wait())
  end
  local ok, process = pcall(vim.system, cmd, opts, function(r)
    vim.schedule(function() coroutine.resume(co, result(r)) end)
  end)
  if not ok then -- (no such program)
    M.fail(("can't run %s: %s"):format(cmd[1], tostring(process)))
  end
  if started then
    started(process)
  end
  return coroutine.yield()
end

-- Whether a program is installed.
function M.has(program)
  return vim.fn.executable(program) == 1
end

function M.need(program, why)
  if not M.has(program) then
    M.fail(("%s is needed %s, and isn't installed"):format(program, why))
  end
end

-- The last lines of a command's output, for an error message.
function M.tail(r, n)
  local lines = vim.split(vim.trim((r.stderr or "") .. "\n" .. (r.stdout or "")), "\n")
  return table.concat(vim.list_slice(lines, math.max(#lines - (n or 15) + 1, 1)), "\n")
end

-- The task's step (percent: how far it is, if known).
function M.say(msg, percent)
  local p = current()
  if not p then
    return vim.schedule(function() vim.notify("[manuscript] " .. msg) end)
  end
  vim.schedule(function() -- (in order, before its end's)
    p.text, p.percent = msg, percent
    show(p)
  end)
  if NATIVE and not p.timer then -- (the time, each second)
    p.timer = vim.uv.new_timer()
    p.timer:start(1000, 1000, vim.schedule_wrap(function() show(p) end))
  end
end

-- How long the next steps took last time (nil: unknown): the percent shown grows with the time.
function M.estimate(seconds)
  local p = current()
  if p then
    p.expect, p.since = seconds, vim.uv.hrtime()
  end
end

-- The share of the task the next steps are (percent from..to): their own percents go within it.
function M.range(from, to)
  local p = current()
  if p then
    vim.schedule(function() p.range = from and { from, to } or nil end) -- (in order with say())
  end
end

function M.title(title)
  local p = current()
  if p then
    p.title = title
  end
end

-- fn, to be called later (a callback) as part of the current task: its say() goes to the task.
function M.bind(fn)
  local p = current()
  return function(...)
    local before = bound
    bound = p
    local ok, err = pcall(fn, ...)
    bound = before
    if not ok then
      error(err, 0)
    end
  end
end

return M
