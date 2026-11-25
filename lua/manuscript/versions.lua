-- :Manuscript versions: the exports and submissions, and the names a version can have (for completion).
local M = {}

function M.show()
  local ok, project = pcall(require("manuscript.project").find)
  if not ok then
    return vim.notify("[manuscript] " .. (type(project) == "table" and project.msg or tostring(project)), vim.log.levels.ERROR)
  end
  local list = require("manuscript.snapshot").list(project)
  if #list == 0 then
    return vim.notify("[manuscript] No export or submission yet: :Manuscript export, :Manuscript submit")
  end
  local lines = {}
  for k, s in ipairs(list) do
    local m = s.manifest
    lines[#lines + 1] = ("@%d  %s  %s  %s%s"):format(k, s.name, (m.date or ""):gsub("T", " "),
      m.commit and m.commit:sub(1, 7) or "(no commit)", m.dirty and " + changes not committed" or "")
  end
  vim.notify("[manuscript] Exports and submissions (for :Manuscript diff @N, or @name):\n" .. table.concat(lines, "\n"))
end

-- The parts (main, appendix1...), @1, @2026-10-23..., ".", and the git tags, branches and recent
-- commits.
function M.names()
  local project = require("manuscript.project").find()
  local out = #project.parts > 1 and vim.tbl_map(function(p) return p.name end, project.parts) or {}
  out[#out + 1] = "."
  for k, s in ipairs(require("manuscript.snapshot").list(project)) do
    out[#out + 1] = "@" .. k
    out[#out + 1] = "@" .. s.name
  end
  if project.git then
    local r = vim.system({ "git", "-C", project.dir, "for-each-ref", "--format=%(refname:short)", "refs/tags", "refs/heads", "refs/remotes" }, { text = true }):wait()
    vim.list_extend(out, vim.split(vim.trim(r.stdout or ""), "\n", { trimempty = true }))
    out[#out + 1] = "HEAD"
    r = vim.system({ "git", "-C", project.dir, "log", "--format=%h", "-15" }, { text = true }):wait()
    vim.list_extend(out, vim.split(vim.trim(r.stdout or ""), "\n", { trimempty = true }))
  end
  return out
end

return M
