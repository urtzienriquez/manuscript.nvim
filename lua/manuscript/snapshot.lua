-- What was exported: each export/<date>/ keeps, in .manuscript/, the LaTeX its Word files were
-- made from (one per part, and all.tex: the whole) and manifest.json: { date, root, parts, files
-- (each part's Word file), commit, dirty }. With uncommitted changes (dirty), also a copy of the sources (.manuscript/sources/), as
-- the commit alone wouldn't give them back.
local job = require("manuscript.job")
local M = {}

local function git(project, args)
  if not project.git then
    return nil
  end
  local r = job.run(vim.list_extend({ "git", "-C", project.dir }, args))
  return r.code == 0 and vim.trim(r.stdout) or nil
end

function M.record(project, folder, texs, files)
  local meta = vim.fs.joinpath(folder, ".manuscript")
  vim.fn.mkdir(meta, "p")
  for name, path in pairs(texs) do
    assert(vim.uv.fs_copyfile(path, vim.fs.joinpath(meta, name .. ".tex")))
  end
  local manifest = {
    date = os.date("%Y-%m-%dT%H:%M:%S"),
    root = vim.fs.basename(project.root),
    parts = vim.tbl_map(function(p) return p.name end, project.parts),
    files = files,
    commit = git(project, { "rev-parse", "HEAD" }),
  }
  local status = git(project, { "status", "--porcelain", "--", "." })
  manifest.dirty = not manifest.commit or (status ~= nil and status ~= "")
  if manifest.dirty then -- (the sources as they were)
    local files = { project.root }
    for _, part in ipairs(project.parts) do
      files[#files + 1] = part.file
    end
    vim.list_extend(files, project.bibs)
    for _, file in ipairs(vim.fn.uniq(vim.fn.sort(files))) do
      local rel = file:sub(#project.dir + 2)
      if vim.startswith(file, project.dir .. "/") and vim.uv.fs_stat(file) then
        local to = vim.fs.joinpath(meta, "sources", rel)
        vim.fn.mkdir(vim.fs.dirname(to), "p")
        assert(vim.uv.fs_copyfile(file, to))
      end
    end
  end
  local f = assert(io.open(vim.fs.joinpath(meta, "manifest.json"), "w"))
  f:write(vim.json.encode(manifest))
  f:close()
end

-- An export's Word file of a part (named <part>.docx before they had the export's date).
function M.docx(s, part)
  return vim.fs.joinpath(s.dir, (s.manifest.files or {})[part] or part .. ".docx")
end

-- The exports of a project, the last first: { name (the folder's: "2026-11-25"), dir, manifest }.
function M.list(project)
  local base = vim.fs.joinpath(project.dir, project.options.export_dir)
  local out = {}
  for name, kind in vim.fs.dir(base) do
    local file = vim.fs.joinpath(base, name, ".manuscript", "manifest.json")
    if kind == "directory" and vim.uv.fs_stat(file) then
      local f = io.open(file)
      local ok, manifest = pcall(vim.json.decode, f and f:read("*a") or "")
      if f then
        f:close()
      end
      if ok and type(manifest) == "table" then
        out[#out + 1] = { name = name, dir = vim.fs.joinpath(base, name), manifest = manifest }
      end
    end
  end
  table.sort(out, function(a, b) return (a.manifest.date or "") > (b.manifest.date or "") end)
  return out
end

-- An export's LaTeX (all.tex, or a part's).
function M.tex(snapshot, part)
  return vim.fs.joinpath(snapshot.dir, ".manuscript", (part or "all") .. ".tex")
end

return M
