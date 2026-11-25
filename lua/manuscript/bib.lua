-- .bib files: their entries, read by their braces (an entry may be on one line or many).
local M = {}

-- { [key] = { type, fields = { [name] = value } } } of a .bib file's text (@comment, @string and
-- @preamble aren't entries).
function M.parse(text)
  local out = {}
  for kind, entry in text:gmatch("@(%a+)%s*(%b{})") do
    local key, body = entry:match("^{%s*([^,%s]+)%s*,(.*)}$")
    if key and not ({ comment = true, string = true, preamble = true })[kind:lower()] then
      local fields = {}
      for name, value in body:gmatch("[%s,]([%a_%-]+)%s*=%s*(%b{})") do
        fields[name:lower()] = fields[name:lower()] or value:sub(2, -2)
      end
      for name, value in body:gmatch('[%s,]([%a_%-]+)%s*=%s*"([^"]*)"') do
        fields[name:lower()] = fields[name:lower()] or value
      end
      for name, value in body:gmatch("[%s,]([%a_%-]+)%s*=%s*(%d+)") do
        fields[name:lower()] = fields[name:lower()] or value
      end
      out[key] = { type = kind:lower(), fields = fields }
    end
  end
  return out
end

function M.read(paths)
  local out = {}
  for _, path in ipairs(paths) do
    local f = io.open(path)
    if f then
      out = vim.tbl_extend("force", out, M.parse(f:read("*a")))
      f:close()
    end
  end
  return out
end

-- Keys renamed from `old` to `new` (entries read by M.parse): the same DOI, or else the same title
-- and year, under another key. { [old key] = new key }
function M.renames(old, new)
  local function id(entry)
    local doi = entry.fields.doi and entry.fields.doi:lower():gsub("^https?://[^/]+/", ""):gsub("%s", "")
    if doi and doi ~= "" then
      return "doi:" .. doi
    end
    local title = (entry.fields.title or ""):lower():gsub("[^%w]", "")
    return title ~= "" and ("title:" .. title .. ":" .. (entry.fields.year or entry.fields.date or ""):sub(1, 4)) or nil
  end
  local by_id = {}
  for key, entry in pairs(new) do
    local i = id(entry)
    if i then
      by_id[i] = key
    end
  end
  local out = {}
  for key, entry in pairs(old) do
    local i = id(entry)
    if not new[key] and i and by_id[i] then
      out[key] = by_id[i]
    end
  end
  return out
end

return M
