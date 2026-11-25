-- :Manuscript respond: the response to the reviewers, response.tex beside the root (opened if it is
-- there). A buffer opens for their comments, as the journal sent them (pasted); :w writes
-- response.tex: a point for each comment (by reviewer, as they numbered them), each quoted, a place
-- for the answer after it. \changed{label} says where a change is in the revised manuscript (its
-- page, from its last build), and :Manuscript submit builds it into response.pdf.
local M = {}

local function escape(text)
  return (text:gsub("[\\{}$&#%%_^~]", function(c)
    return ({ ["\\"] = "\\textbackslash{}", ["^"] = "\\textasciicircum{}", ["~"] = "\\textasciitilde{}" })[c] or "\\" .. c
  end))
end

-- How reviewers number their comments: a line starting so is a new point ({ pattern: id, rest }).
local NUMBERED = {
  "^%s*(%d+)[%.%)]%s+(.*)$", -- 1. or 1)
  "^%s*%((%d+)%)%s+(.*)$", -- (1)
  "^%s*[Cc]omment%s*(%d+)%s*[%.:%)%-]?%s*(.*)$", -- Comment 1:
  "^%s*R%d*%s*[%.%-]?%s*(%d+)%s*[%.:%)]?%s+(.*)$", -- R1.4, R2-3
  "^%s*[-*•]()%s+(.*)$", -- a bullet (numbered in order)
}

local function numbered(line)
  for _, pattern in ipairs(NUMBERED) do
    local id, rest = line:match(pattern)
    if id then
      return type(id) == "number" and "" or id, rest
    end
  end
end

-- A line naming who wrote what follows: "Reviewer 2", "Referee #1:", "Comments of reviewer 3",
-- "Associate Editor", "Editor's comments".
local function reviewer(line)
  local l = vim.trim(line):gsub(":$", "")
  if #l > 60 or l:match("%.$") then
    return nil
  end
  if l:match("[Rr]eviewer%s*#?%s*%d+") or l:match("[Rr]eferee%s*#?%s*%d+") or l:match("^[%a%s']*[Ee]ditor[%a%s']*$") then
    return l
  end
end

-- The comments of a decision letter: { { reviewer, points = { { id, text } } } }. A reviewer starts
-- at a line naming one; a point at a line numbered as reviewers do (1., 2), (3), Comment 4, R1.5, a
-- bullet) or, if none is, at each paragraph. Points without a number get one, in order.
function M.split(text)
  local any = false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    any = any or numbered(line) ~= nil
  end
  local out, current, point = {}, nil, nil
  local function add(id, first)
    if not current then
      current = { reviewer = "Comments", points = {} }
      out[#out + 1] = current
    end
    point = { id = id, text = first }
    current.points[#current.points + 1] = point
  end
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local who = reviewer(line)
    local id, rest = numbered(line)
    if who then
      current, point = { reviewer = who, points = {} }, nil
      out[#out + 1] = current
    elseif vim.trim(line) == "" then
      if not any then
        point = nil
      elseif point then
        point.text = point.text .. "\n\n"
      end
    elseif any and id then
      add(id, rest)
    elseif point then
      point.text = point.text .. (point.text:match("\n$") and "" or " ") .. vim.trim(line)
    else
      add("", vim.trim(line))
    end
  end
  for _, r in ipairs(out) do
    for n, p in ipairs(r.points) do
      p.id = p.id ~= "" and p.id or tostring(n)
      p.text = vim.trim((p.text:gsub("\n\n+", "\n\n")))
    end
  end
  return vim.tbl_filter(function(r) return #r.points > 0 end, out)
end

-- response.tex for these comments; `aux`: the revised manuscript's labels (its build's .aux, relative
-- to the root's folder, without .aux).
function M.document(reviews, aux)
  local out = {
    "% the response to the reviewers (:Manuscript submit builds it into response.pdf)",
    "\\documentclass[11pt]{article}",
    "\\usepackage[a4paper, margin=1in]{geometry}",
    "\\usepackage{xcolor}",
    "\\usepackage{xr}",
    "% the labels of the revised manuscript (its last build): \\changed{fig:map} says on which page it is",
    "\\externaldocument[ms-]{" .. aux .. "}",
    "\\newcommand{\\changed}[1]{(page~\\pageref{ms-#1})}",
    "\\newenvironment{reviewer}{\\par\\medskip\\noindent\\color{gray!50!black}\\itshape}{\\par\\medskip}",
    "\\setlength{\\parindent}{0pt}",
    "\\begin{document}",
    "",
    "\\section*{Response to the reviewers}",
    "",
    "Dear Editor,",
    "",
    "We thank you and the reviewers for their comments. Below, we answer each of them (in italics), and",
    "say where the manuscript changed.",
    "",
  }
  for r, review in ipairs(reviews) do
    out[#out + 1] = "\\section*{" .. escape(review.reviewer) .. "}"
    out[#out + 1] = ""
    for _, p in ipairs(review.points) do
      local id = p.id:find("[%.%-]") and p.id or r .. "." .. p.id
      out[#out + 1] = "\\subsection*{" .. escape(id) .. "}"
      out[#out + 1] = "\\begin{reviewer}"
      out[#out + 1] = escape(p.text)
      out[#out + 1] = "\\end{reviewer}"
      out[#out + 1] = ""
      out[#out + 1] = "% your answer"
      out[#out + 1] = ""
    end
  end
  out[#out + 1] = "\\end{document}"
  return table.concat(out, "\n") .. "\n"
end

function M.run()
  local ok, project = pcall(require("manuscript.project").find)
  if not ok then
    return vim.notify("[manuscript] " .. (type(project) == "table" and project.msg or tostring(project)), vim.log.levels.ERROR)
  end
  local path = vim.fs.joinpath(project.dir, "response.tex")
  if vim.uv.fs_stat(path) then
    return vim.cmd.edit(vim.fn.fnameescape(path))
  end
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, "manuscript://reviews")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# Paste the reviewers' comments here (replacing these lines), as the journal sent them; then :w",
    "# writes response.tex beside " .. vim.fs.basename(project.root) .. ", with a point for each comment.",
  })
  vim.bo[buf].modified = false
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local lines = vim.tbl_filter(function(l) return not l:match("^# ") end, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      local reviews = M.split(table.concat(lines, "\n"))
      if #reviews == 0 then
        return vim.notify("[manuscript] No comments to answer: paste them first", vim.log.levels.WARN)
      end
      local f = assert(io.open(path, "w"))
      f:write(M.document(reviews, ".build/" .. project.name .. "/" .. project.name))
      f:close()
      vim.bo[buf].modified = false
      vim.cmd("bwipeout")
      vim.cmd.edit(vim.fn.fnameescape(path))
      local n = 0
      for _, r in ipairs(reviews) do
        n = n + #r.points
      end
      vim.notify(("[manuscript] response.tex: %d comments of %d reviewers to answer"):format(n, #reviews))
    end,
  })
end

return M
