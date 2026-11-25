-- :Manuscript archive: the code and data of the manuscript's repository in one zip, for Zenodo or
-- Dryad: submission/<repository>-<date>.zip. Its files: those git tracks (as they are now), and
-- those of the option `archive.include` (results kept out of git: `{ "results/*.rds" }`), but those
-- of `archive.exclude`; globs relative to the repository.
local job = require("manuscript.job")
local M = {}

-- The files to archive (relative to the repository `top`), sorted.
function M.files(top, options)
  local r = job.run({ "git", "-C", top, "ls-files", "-z" })
  if r.code ~= 0 then
    job.fail("git ls-files failed:\n" .. job.tail(r))
  end
  local set = {}
  for file in (r.stdout or ""):gmatch("([^%z]+)") do
    if vim.uv.fs_stat(vim.fs.joinpath(top, file)) then -- (not one deleted since)
      set[file] = true
    end
  end
  local function glob(patterns)
    local out = {}
    for _, pattern in ipairs(patterns or {}) do
      for _, path in ipairs(vim.fn.globpath(top, pattern, false, true)) do
        if vim.fn.isdirectory(path) == 1 then
          for rel, kind in vim.fs.dir(path, { depth = math.huge }) do
            if kind == "file" then
              out[#out + 1] = vim.fs.joinpath(path, rel):sub(#top + 2)
            end
          end
        else
          out[#out + 1] = path:sub(#top + 2)
        end
      end
    end
    return out
  end
  for _, file in ipairs(glob((options or {}).include)) do
    set[file] = true
  end
  for _, file in ipairs(glob((options or {}).exclude)) do
    set[file] = nil
  end
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

function M.run(args, on_done)
  job.task(function()
    local project = require("manuscript.project").find()
    if not project.git then
      job.fail("the manuscript isn't in a git repository: what to archive is what git tracks")
    end
    job.need("zip", "to make the archive")
    job.title("archive")
    local top = project.git
    local files = M.files(top, project.options.archive)
    local base = vim.fs.joinpath(project.dir, "submission")
    vim.fn.mkdir(base, "p")
    if not vim.uv.fs_stat(vim.fs.joinpath(base, ".gitignore")) then
      vim.fn.writefile({ "*" }, vim.fs.joinpath(base, ".gitignore"))
    end
    local zip = vim.fs.joinpath(base, vim.fs.basename(top) .. "-" .. os.date("%Y-%m-%d") .. ".zip")
    os.remove(zip)
    job.say(("zipping %d files"):format(#files))
    local r = job.run({ "zip", "-q", "-X", zip, "-@" }, { cwd = top, stdin = table.concat(files, "\n") .. "\n" })
    if r.code ~= 0 then
      job.fail("zip failed:\n" .. job.tail(r))
    end
    local dirty = job.run({ "git", "-C", top, "status", "--porcelain" }).stdout or ""
    local size = (vim.uv.fs_stat(zip) or { size = 0 }).size
    job.say(("%s ready: %d files, %.1f MB%s"):format(vim.fn.fnamemodify(zip, ":~:."), #files, size / 1e6,
      dirty ~= "" and " (with changes not committed: as the files are now)" or ""))
  end, on_done, "archive")
end

return M
