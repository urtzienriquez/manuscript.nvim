-- Turn the knitted LaTeX of one manuscript part into the text pandoc reads.
--
-- This is a byte-for-byte port of two Python scripts (prepare.py, then
-- preprocess.py). Python regular expressions are emulated with Lua patterns
-- and small scanners; quirks of the original are kept on purpose so that the
-- output stays identical.

local bit = require("bit")

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Replace every plain (non-pattern) occurrence of `old` by `new`.
local function replace(s, old, new)
  local out, pos = {}, 1
  while true do
    local i = s:find(old, pos, true)
    if not i then break end
    out[#out + 1] = s:sub(pos, i - 1)
    out[#out + 1] = new
    pos = i + #old
  end
  out[#out + 1] = s:sub(pos)
  return table.concat(out)
end

-- Like re.sub: `match(text, pos)` returns s, e, captures... of the next match
-- at or after pos, and `repl(...)` gets the captures.
local function sub_fn(text, match, repl)
  local out, pos = {}, 1
  while true do
    local r = { match(text, pos) }
    if not r[1] then break end
    out[#out + 1] = text:sub(pos, r[1] - 1)
    out[#out + 1] = repl(unpack(r, 3))
    pos = r[2] + 1
  end
  out[#out + 1] = text:sub(pos)
  return table.concat(out)
end

-- Leftmost match of the literal `lit` followed by one of the Lua patterns in
-- `alts`, tried in order (this emulates an optional group or an alternation).
local function find_alt(text, init, lit, alts)
  while true do
    local s = text:find(lit, init, true)
    if not s then return nil end
    for _, pat in ipairs(alts) do
      local r = { text:find("^" .. pat, s + #lit) }
      if r[1] then return s, r[2], unpack(r, 3) end
    end
    init = s + 1
  end
end

-- Remove every match of `lit` followed by one of `alts`.
local function remove_alt(text, lit, alts)
  return sub_fn(text, function(t, pos) return find_alt(t, pos, lit, alts) end,
    function() return "" end)
end

-- Position just after the brace that closes the first "{" at or after
-- `start`, ignoring escaped braces (Python's find_balanced). When there is no
-- "{", Python starts the scan at index -1, i.e. the last character first.
local function find_balanced(text, start)
  local n, count = #text, 0
  local i = text:find("{", start, true)
  if not i then
    local c = text:byte(n)
    if c == 123 then count = 1 elseif c == 125 then count = -1 end
    i = 1
  end
  while true do
    i = text:find("[{}]", i)
    if not i then return nil end
    local j, bs = i - 1, 0
    while j >= 1 and text:byte(j) == 92 do
      bs, j = bs + 1, j - 1
    end
    if bs % 2 == 0 then
      count = count + (text:byte(i) == 123 and 1 or -1)
      if count == 0 then return i + 1 end
    end
    i = i + 1
  end
end

-- Emulates `((?:[^{}]|\{[^{}]*\})*)\}` starting at `i`: text with at most one
-- level of braces, then "}". Returns the position of that "}" or nil.
local function flat_group_end(text, i)
  while true do
    local k = text:find("[{}]", i)
    if not k then return nil end
    if text:byte(k) == 125 then return k end
    local close = text:find("[{}]", k + 1)
    if not close or text:byte(close) ~= 125 then return nil end
    i = close + 1
  end
end

-- SHA-1 hex digest (used to name unlabelled TikZ pictures, as Python does).
local function sha1(msg)
  local band, bor, bxor, bnot, rol, tobit =
    bit.band, bit.bor, bit.bxor, bit.bnot, bit.rol, bit.tobit
  local h0, h1, h2, h3, h4 =
    tobit(0x67452301), tobit(0xEFCDAB89), tobit(0x98BADCFE), tobit(0x10325476), tobit(0xC3D2E1F0)
  local bits = #msg * 8
  local hi, lo = math.floor(bits / 2 ^ 32), bits % 2 ^ 32
  local function be32(x)
    return string.char(math.floor(x / 2 ^ 24) % 256, math.floor(x / 2 ^ 16) % 256,
      math.floor(x / 2 ^ 8) % 256, x % 256)
  end
  msg = msg .. "\128" .. string.rep("\0", (55 - #msg) % 64) .. be32(hi) .. be32(lo)
  local w = {}
  for chunk = 1, #msg, 64 do
    for t = 0, 15 do
      local a, b, c, d = msg:byte(chunk + t * 4, chunk + t * 4 + 3)
      w[t] = bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d)
    end
    for t = 16, 79 do
      w[t] = rol(bxor(w[t - 3], w[t - 8], w[t - 14], w[t - 16]), 1)
    end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for t = 0, 79 do
      local f, k
      if t < 20 then
        f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif t < 40 then
        f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif t < 60 then
        f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
      else
        f, k = bxor(b, c, d), 0xCA62C1D6
      end
      local temp = tobit(rol(a, 5) + f + e + k + w[t])
      a, b, c, d, e = temp, a, rol(b, 30), c, d
    end
    h0, h1, h2, h3, h4 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d), tobit(h4 + e)
  end
  return bit.tohex(h0) .. bit.tohex(h1) .. bit.tohex(h2) .. bit.tohex(h3) .. bit.tohex(h4)
end

-- ---------------------------------------------------------------------------
-- Step A: prepare.py
-- ---------------------------------------------------------------------------

-- Emulates ^\\(title|author|affil)(\[[^]]*\])?\{.*\}\n at `pos`: returns the
-- position of the final newline or nil.
local function title_line_end(tex, pos)
  for _, name in ipairs({ "title", "author", "affil" }) do
    if tex:sub(pos, pos + #name) == "\\" .. name then
      local p = pos + #name + 1
      local _, close = tex:find("^%[[^%]]*%]", p)
      if close then p = close + 1 end
      if tex:byte(p) == 123 then
        local eol = tex:find("\n", p, true)
        if eol and eol - 1 > p and tex:byte(eol - 1) == 125 then return eol end
      end
      return nil
    end
  end
end

-- Drop the \title, \author and \affil lines (appendices only).
local function strip_title_lines(tex)
  local out, pos, n = {}, 1, #tex
  while pos <= n do
    local e = title_line_end(tex, pos)
    if e then
      pos = e + 1
    else
      local stop = tex:find("\n", pos, true) or n
      out[#out + 1] = tex:sub(pos, stop)
      pos = stop + 1
    end
  end
  return table.concat(out)
end

-- "\clearpage \nolinenumbers ... \renewcommand{\thesection}{Sn.\arabic{section}}"
-- (plus the following S-numbering lines) -> \appendixsetup{n}\label{appendixn}
local function find_appendix_start(tex, pos)
  local head = "\\clearpage\n\\nolinenumbers\n"
  local s = tex:find(head, pos, true)
  if not s then return nil end
  local _, e, num = tex:find("\\renewcommand{\\thesection}{S(%d)%.\\arabic{section}}\n", s + #head)
  if not e then return nil end
  while true do
    local _, e2 = tex:find("^\\renewcommand{\\the[%w_]+}{S%d%.\\arabic{[%w_]+}}\n", e + 1)
    if not e2 then break end
    e = e2
  end
  return s, e, num
end

-- \begin{tabular}[x]{@{}l@{}} ... \end{tabular} -> its content on one line
local function find_one_col_tabular(tex, pos)
  while true do
    local s = tex:find("\\begin{tabular}", pos, true)
    if not s then return nil end
    local q = s + 15
    if tex:find("^%[[a-z]%]", q) then q = q + 3 end
    if tex:find("^{@{}[lcr]@{}}", q) then
      local e = tex:find("\\end{tabular}", q + 9, true)
      if not e then return nil end
      return s, e + 12, tex:sub(q + 9, e - 1)
    end
    pos = s + 1
  end
end

-- \shortstack[x]{a\\b} -> "a b"
local function find_shortstack(tex, pos)
  while true do
    local s = tex:find("\\shortstack", pos, true)
    if not s then return nil end
    local q = s + 11
    if tex:find("^%[[a-z]%]", q) then q = q + 3 end
    if tex:byte(q) == 123 then
      local close = flat_group_end(tex, q + 1)
      if close then return s, close, tex:sub(q + 1, close - 1) end
    end
    pos = s + 1
  end
end

-- \endfirsthead ... \endhead -> \endhead
local function find_firsthead(tex, pos)
  local s = tex:find("\\endfirsthead", pos, true)
  if not s then return nil end
  local e = tex:find("\\endhead", s + 13, true)
  if not e then return nil end
  return s, e + 7
end

local function one_line(body) return replace(body, "\\\\", " ") end

local function prepare_part(tex, name, repo)
  if name:sub(1, 8) == "appendix" then
    tex = strip_title_lines(tex)
  end
  tex = replace(tex, "{../figures", "{" .. repo .. "/figures")
  tex = sub_fn(tex, find_appendix_start, function(num)
    return "\\appendixsetup{" .. num .. "}\\label{appendix" .. num .. "}\n"
  end)
  tex = replace(tex, "$-$", "−")
  tex = sub_fn(tex, find_one_col_tabular, one_line)
  tex = sub_fn(tex, find_shortstack, one_line)
  tex = sub_fn(tex, find_firsthead, function() return "\\endhead" end)
  return tex
end

-- ---------------------------------------------------------------------------
-- Step B: preprocess.py
-- ---------------------------------------------------------------------------

-- Remove \hlxxx{...} wrappers (keeping their content) and unescape braces.
local function strip_hl(text)
  local parts, i, n = {}, 1, #text
  while i <= n do
    local _, brace = text:find("^\\hl[a-z]+{", i)
    local close = brace and find_balanced(text, brace)
    if close then
      parts[#parts + 1] = text:sub(brace + 1, close - 2)
      i = close
    else
      parts[#parts + 1] = text:sub(i, i)
      i = i + 1
    end
  end
  return replace(replace(table.concat(parts), "\\{", "{"), "\\}", "}")
end

-- alltt environments -> verbatim (pandoc refuses \textcolor inside alltt)
local function process_alltt(content)
  local result, pos = {}, 1
  while true do
    local s = content:find("\\begin{alltt}", pos, true)
    if not s then
      result[#result + 1] = content:sub(pos)
      break
    end
    result[#result + 1] = content:sub(pos, s - 1)
    local e = content:find("\\end{alltt}", s, true)
    if not e then
      result[#result + 1] = content:sub(s)
      break
    end
    result[#result + 1] = "\\begin{verbatim}" .. strip_hl(content:sub(s + 13, e - 1)) .. "\\end{verbatim}"
    pos = e + 11
  end
  return table.concat(result)
end

-- knitr Shaded/Highlighting blocks -> verbatim
local function process_shaded(content)
  local result, pos = {}, 1
  while true do
    local s = content:find("\\begin{Shaded}", pos, true)
    if not s then
      result[#result + 1] = content:sub(pos)
      break
    end
    result[#result + 1] = content:sub(pos, s - 1)
    local e = content:find("\\end{Shaded}", s, true)
    if not e then
      result[#result + 1] = content:sub(s)
      break
    end
    local inner = content:sub(s + 14, e - 1)
    local hl_start = inner:find("\\begin{Highlighting}", 1, true)
    local hl_end, header_end
    if hl_start then
      header_end = inner:find("\n", hl_start, true) or hl_start + 20
      hl_end = inner:find("\\end{Highlighting}", header_end, true)
    end
    if hl_end then
      local code = inner:sub(header_end, hl_end - 1):gsub("^\n+", ""):gsub("\n+$", "")
      result[#result + 1] = "\\begin{verbatim}" .. strip_hl(code) .. "\\end{verbatim}"
    else
      result[#result + 1] = inner
    end
    pos = e + 12
  end
  return table.concat(result)
end

-- \appendixsetup{n} ... \label{x} -> marker paragraph "TOWORDAPPENDIX:n:x"
-- (the label is moved into the marker; the text in between is kept)
local function find_appendixsetup(text, pos)
  local s, e, num = text:find("\\appendixsetup{(%d+)}", pos)
  if not s then return nil end
  local from = e + 1
  while true do
    local l = text:find("\\label{", from, true)
    if not l then return nil end
    local _, le, label = text:find("^([^}]+)}", l + 7)
    if le then return s, le, num, text:sub(e + 1, l - 1), label end
    from = l + 1
  end
end

-- \cmd{a}{b}{c} -> the `keep`-th argument (0-based, as in Python)
local function unwrap_command(text, cmd, nargs, keep)
  local out, pos = {}, 1
  while true do
    local i = text:find(cmd .. "{", pos, true)
    if not i then
      out[#out + 1] = text:sub(pos)
      break
    end
    out[#out + 1] = text:sub(pos, i - 1)
    local j, args = i + #cmd, {}
    for k = 1, nargs do
      local e = find_balanced(text, j)
      args[k] = text:sub(j + 1, e - 2)
      j = e
    end
    out[#out + 1] = args[keep + 1]
    pos = j
  end
  return table.concat(out)
end

-- siunitx ------------------------------------------------------------------

local UNITS = {
  celsius = "°C", degreeCelsius = "°C", kelvin = "K", K = "K", degree = "°",
  percent = "\\%", metre = "m", meter = "m", m = "m", cm = "cm", mm = "mm",
  km = "km", gram = "g", g = "g", kg = "kg", mg = "mg", litre = "L",
  liter = "L", L = "L", ml = "mL", mL = "mL", second = "s", s = "s",
  minute = "min", hour = "h", h = "h", day = "d", d = "d", joule = "J",
  J = "J", kJ = "kJ", watt = "W", W = "W", mole = "mol", mol = "mol",
  pascal = "Pa", hectare = "ha", volt = "V",
}
local PREFIXES = { milli = "m", micro = "µ", centi = "c", kilo = "k", mega = "M",
  nano = "n", deci = "d" }
local SI_ARGS = { qty = 2, SI = 2, si = 1, unit = 1, num = 1, ang = 1 }
local ENV_MATH = { equation = true, ["equation*"] = true, align = true, ["align*"] = true,
  gather = true, ["gather*"] = true, multline = true, ["multline*"] = true, displaymath = true }
-- Python's \s on ASCII text (it also includes \x1c-\x1f)
local NOT_WS_OR_BS = "^[^\\ \t\n\r\f\v\28-\31]+"

-- Built-in units plus those declared with \DeclareSIUnit{\name}{symbol}.
local function declared_units(content)
  local units = {}
  for k, v in pairs(UNITS) do units[k] = v end
  local pos = 1
  while true do
    local s = content:find("\\DeclareSIUnit", pos, true)
    if not s then break end
    local q = s + 14
    local _, oe = content:find("^%[[^%]]*%]", q)
    if oe then q = oe + 1 end
    local _, e, name = content:find("^{\\([%w_]+)}{", q)
    local close = e and flat_group_end(content, e + 1)
    if close then
      units[name] = content:sub(e + 1, close - 1)
      pos = close + 1
    else
      pos = s + 1
    end
  end
  return units
end

-- A siunitx unit argument -> list of { symbol, power }.
local function parse_units(arg, units_tbl)
  local units, prefix, per = {}, "", false
  local i, n = 1, #arg
  while i <= n do
    local tok = arg:match("^\\[A-Za-z]+", i) or (arg:byte(i) ~= 92 and arg:match(NOT_WS_OR_BS, i))
    if not tok then
      i = i + 1
    else
      i = i + #tok
      local name = tok:sub(1, 1) == "\\" and tok:sub(2) or nil
      if name == "per" then
        per = true
      elseif name and PREFIXES[name] then
        prefix = prefix .. PREFIXES[name]
      elseif name == "squared" or name == "cubed" then
        local last = units[#units]
        last[2] = last[2] * (name == "squared" and 2 or 3)
      else
        local sym = name and (units_tbl[name] or name) or tok
        units[#units + 1] = { prefix .. sym, per and -1 or 1 }
        prefix, per = "", false
      end
    end
  end
  return units
end

-- Trim, and turn a leading "-" into a real minus sign.
local function fmt_number(n)
  n = n:match("^%s*(.-)%s*$")
  if n:sub(1, 1) == "-" then n = "−" .. n:sub(2) end
  return n
end

local function fmt_units(units, math)
  local parts = {}
  for _, u in ipairs(units) do
    local sym, p = u[1], u[2]
    local s
    if math then
      s = "\\mathrm{" .. sym .. "}"
      if p ~= 1 then s = s .. "^{" .. tostring(p) .. "}" end
    else
      s = sym
      if p ~= 1 then s = s .. "\\textsuperscript{" .. replace(tostring(p), "-", "−") .. "}" end
    end
    parts[#parts + 1] = s
  end
  return table.concat(parts, "\\,")
end

local function si_replace(cmd, args, math, units_tbl)
  if cmd == "qty" or cmd == "SI" then
    return fmt_number(args[1]) .. (math and "\\," or "~") .. fmt_units(parse_units(args[2], units_tbl), math)
  elseif cmd == "si" or cmd == "unit" then
    return fmt_units(parse_units(args[1], units_tbl), math)
  elseif cmd == "num" then
    return fmt_number(args[1])
  elseif cmd == "ang" then
    return fmt_number(args[1]) .. (math and "^{\\circ}" or "°")
  end
end

-- Scan the text, tracking math mode, and replace siunitx commands by plain
-- text (text mode) or \mathrm (math mode).
local function convert_siunitx(text, units_tbl)
  local out, i, n, math = {}, 1, #text, false
  while i <= n do
    local k = text:find("[\\%%$]", i)
    if not k then
      out[#out + 1] = text:sub(i)
      break
    end
    out[#out + 1] = text:sub(i, k - 1)
    i = k
    local c = text:sub(i, i)
    if c == "\\" then
      local name, j = text:match("^\\([A-Za-z]+)()", i)
      if j and text:byte(j) == 42 then j = j + 1 end -- optional star
      local nxt = j and text:sub(j, j)
      if name and SI_ARGS[name] and (nxt == "{" or nxt == "[") then
        if nxt == "[" then j = text:find("]", j, true) + 1 end -- skip options
        local args = {}
        for a = 1, SI_ARGS[name] do
          local e = find_balanced(text, j)
          args[a] = text:sub(j + 1, e - 2)
          j = e
        end
        out[#out + 1] = si_replace(name, args, math, units_tbl)
        i = j
      else
        local two = text:sub(i, i + 1)
        if two == "\\(" or two == "\\[" then
          math = true
          out[#out + 1] = two
          i = i + 2
        elseif two == "\\)" or two == "\\]" then
          math = false
          out[#out + 1] = two
          i = i + 2
        else
          local whole, kind, env = text:match("^(\\(%a+){([^}]+)})", i)
          if whole and (kind == "begin" or kind == "end") and ENV_MATH[env] then
            math = kind == "begin"
            out[#out + 1] = whole
            i = i + #whole
          else
            out[#out + 1] = two -- escaped char or other command
            i = i + 2
          end
        end
      end
    elseif c == "%" then -- comment: copy to end of line
      local j = text:find("\n", i, true) or n + 1
      out[#out + 1] = text:sub(i, j - 1)
      i = j
    else -- "$" or "$$" toggles math mode
      if text:sub(i, i + 1) == "$$" then
        out[#out + 1] = "$$"
        i = i + 2
      else
        out[#out + 1] = "$"
        i = i + 1
      end
      math = not math
    end
  end
  return table.concat(out)
end

-- Figures ------------------------------------------------------------------

-- \begin{figure} ... \end{figure} (or figure*), non-greedy
local function find_figure(text, pos)
  while true do
    local s = text:find("\\begin{figure", pos, true)
    if not s then return nil end
    local _, b = text:find("^%*?}", s + 13)
    if b then
      local from = b + 1
      while true do
        local e = text:find("\\end{figure", from, true)
        if not e then return nil end
        local _, ee = text:find("^%*?}", e + 11)
        if ee then return s, ee, text:sub(s, ee) end
        from = e + 1
      end
    end
    pos = s + 1
  end
end

-- Python's \b after an ASCII letter: the next char is not a word char
-- (non-ASCII bytes are taken as word chars).
local function word_boundary(text, i)
  local b = text:byte(i)
  return not b or not (b >= 128 or text:sub(i, i):match("[%w_]"))
end

-- Drop \begin{center}, \end{center} and \centering inside a figure.
local function clean_figure(body)
  local out, pos = {}, 1
  while true do
    local k = body:find("\\", pos, true)
    if not k then break end
    local len
    if body:sub(k, k + 13) == "\\begin{center}" then
      len = 14
    elseif body:sub(k, k + 11) == "\\end{center}" then
      len = 12
    elseif body:sub(k, k + 9) == "\\centering" and word_boundary(body, k + 10) then
      len = 10
    end
    if len then
      out[#out + 1] = body:sub(pos, k - 1)
      pos = k + len
    else
      out[#out + 1] = body:sub(pos, k)
      pos = k + 1
    end
  end
  out[#out + 1] = body:sub(pos)
  return table.concat(out)
end

-- \multirow{n}{width}[vmove]{text} -> text
local function unwrap_multirow(text)
  local out, pos = {}, 1
  while true do
    local i = text:find("\\multirow{", pos, true)
    if not i then
      out[#out + 1] = text:sub(pos)
      break
    end
    out[#out + 1] = text:sub(pos, i - 1)
    local j = find_balanced(text, i + 9) -- {n}
    j = find_balanced(text, j) -- {width}
    if text:sub(j, j) == "[" then j = text:find("]", j, true) + 1 end -- [vmove]
    local e = find_balanced(text, j) -- {text}
    out[#out + 1] = text:sub(j + 1, e - 2)
    pos = e
  end
  return table.concat(out)
end

-- TikZ ---------------------------------------------------------------------

-- Default renderer: pdflatex then pdftocairo -svg in `dir`; returns the svg
-- file name. An existing svg is reused.
function M.render_tikz(standalone_tex, base_name, dir)
  local svg = base_name .. ".svg"
  local path = dir .. "/" .. base_name
  if vim.uv.fs_stat(dir .. "/" .. svg) then return svg end
  local f = assert(io.open(path .. ".tex", "w"))
  f:write(standalone_tex)
  f:close()
  vim.system({ "pdflatex", "-interaction=batchmode", base_name .. ".tex" }, { cwd = dir }):wait()
  vim.system({ "pdftocairo", "-svg", base_name .. ".pdf", svg }, { cwd = dir }):wait()
  for _, ext in ipairs({ ".tex", ".log", ".aux" }) do
    os.remove(path .. ext)
  end
  return svg
end

-- Python's re.sub(r'[^\w\\-]', '_', label); multi-byte chars are kept.
local function sanitize_label(label)
  return (label:gsub("[%z\1-\127\194-\244][\128-\191]*", function(ch)
    if #ch > 1 or ch:match("[%w_\\%-]") then return ch end
    return "_"
  end))
end

-- Render each tikzpicture to svg and replace it by \includegraphics.
local function process_tikz(content, render)
  local libs = {}
  for lib in content:gmatch("\\usetikzlibrary{.-}") do libs[#libs + 1] = lib end
  local tikzsets, search_pos = {}, 1
  while true do
    local s = content:find("\\tikzset", search_pos, true)
    if not s then break end
    local e = find_balanced(content, s)
    if e then
      tikzsets[#tikzsets + 1] = content:sub(s, e - 1)
      search_pos = e
    else
      search_pos = search_pos + 7 -- (sic) from the old position, not from s
    end
  end
  local shared_styles = table.concat(libs, "\n") .. "\n" .. table.concat(tikzsets, "\n")

  local function figure_label(tikz_start)
    local fig_start
    local p = 1
    while true do
      local f = content:find("\\begin{figure}", p, true)
      if not f or f + 13 >= tikz_start then break end
      fig_start, p = f, f + 1
    end
    if not fig_start then return nil end
    local fig_end = content:find("\\end{figure}", tikz_start, true)
    if not fig_end then return nil end
    return content:sub(fig_start, fig_end - 1):match("\\label{fig:([^}]*)}")
  end

  local matches, pos = {}, 1
  while true do
    local s, e = content:find("\\begin{tikzpicture}.-\\end{tikzpicture}", pos)
    if not s then break end
    matches[#matches + 1] = { s, e }
    pos = e + 1
  end
  for m = #matches, 1, -1 do
    local s, e = matches[m][1], matches[m][2]
    local code = content:sub(s, e)
    local label = figure_label(s)
    local base_name = label and ("tikz_" .. sanitize_label(label)) or ("tikz_" .. sha1(code):sub(1, 16))
    local standalone = "\\documentclass{standalone}\n\\usepackage{tikz}\n"
      .. "\\usetikzlibrary{positioning,backgrounds,arrows.meta,calc}\n"
      .. shared_styles .. "\n\\begin{document}\n" .. code .. "\n\\end{document}"
    local svg = render(standalone, base_name) or (base_name .. ".svg")
    content = content:sub(1, s - 1) .. "\\includegraphics[width=\\textwidth]{" .. svg .. "}" .. content:sub(e + 1)
  end
  return content
end

-- authblk -> plain author and affiliation block after \maketitle
local function process_authblk(content)
  local authors, affils = {}, {}
  for num, name in content:gmatch("\\author%[([^%]]+)%]{([^}]*)}") do
    authors[#authors + 1] = name .. "\\textsuperscript{" .. num .. "}"
  end
  if #authors == 0 then return content end
  for num, affil in content:gmatch("\\affil%[([^%]]+)%]{([^}]*)}") do
    affils[#affils + 1] = "\\textsuperscript{" .. num .. "} " .. affil
  end
  local author_str
  if #authors <= 2 then
    author_str = table.concat(authors, " and ")
  else
    author_str = table.concat(authors, ", ", 1, #authors - 1) .. " \\& " .. authors[#authors]
  end
  local block = "\\begin{center}" .. author_str .. "\\end{center}\n\\begin{flushleft}"
    .. table.concat(affils, "\\\\") .. "\\end{flushleft}"
  content = content:gsub("\\author%[[^%]]+%]{[^}]*}\n?", "")
  content = content:gsub("\\affil%[[^%]]+%]{[^}]*}\n?", "")
  content = replace(content, "\\usepackage{authblk}\n", "")
  content = replace(content, "\\usepackage{authblk}", "")
  content = replace(content, "\\date{\\today}\n", "")
  content = replace(content, "\\date{\\today}", "")
  return replace(content, "\\maketitle", "\\maketitle\n\n" .. block .. "\n\n\\vspace{1em}")
end

local function preprocess(content, render)
  -- title and authors, for the \appendixtitleblock expansion
  local paper_title = content:match("\\title{([^}]*)}") or ""
  local raw_authors = {}
  local pos = 1
  while true do
    local s, e, name = find_alt(content, pos, "\\author", { "%[[^%]]+%]{([^}]*)}", "{([^}]*)}" })
    if not s then break end
    raw_authors[#raw_authors + 1] = name
    pos = e + 1
  end
  local paper_authors = table.concat(raw_authors, "; ")

  -- \nptextcite -> \textcite
  content = content:gsub("\\nptextcite{([^}]*)}", function(k) return "\\textcite{" .. k .. "}" end)

  -- \printbibliography -> \section{References} for the refsection filter
  content = content:gsub("\\printbibliography%[heading=bibnumbered,%s*title={References}%]",
    function() return "\\section{References}\n\\printbibliography[heading=none]" end)

  content = process_authblk(content)

  if content:find("\\begin{tikzpicture}", 1, true) then
    content = process_tikz(content, render)
  end

  -- \appendixtitleblock{n}\label{x} -> centered appendix heading
  content = content:gsub("\\appendixtitleblock{(%d+)}%s*\\label{([^}]+)}", function(num, label)
    return "\\begin{center}\n{\\Large\\textbf{Appendix " .. num .. "} \\textit{for:} " .. paper_title
      .. "}\n\n{\\large " .. paper_authors .. "}\n\\end{center}\n\n\\label{" .. label .. "}"
  end)

  content = process_alltt(content)
  content = process_shaded(content)

  -- knitr wrapper environments and colour commands (no-ops in DOCX)
  for _, env in ipairs({ "\\begin{knitrout}", "\\end{knitrout}", "\\begin{kframe}", "\\end{kframe}" }) do
    content = replace(content, env, "")
  end
  content = remove_alt(content, "\\definecolor{shadecolor}{rgb}{",
    { "[^}]*}\\color{fgcolor}\\begin{kframe}", "[^}]*}\\color{fgcolor}" })

  content = sub_fn(content, find_appendixsetup, function(num, between, label)
    return "\n\nTOWORDAPPENDIX:" .. num .. ":" .. label .. "\n\n" .. between
  end)

  -- \resizebox{w}{h}{content} -> content (pandoc cannot read tables inside it)
  content = unwrap_command(content, "\\resizebox", 3, 2)

  -- siunitx, in the document body only. Without \begin{document} Python's
  -- find() gives -1 and only the last character is scanned.
  local units_tbl = declared_units(content)
  local body_start = content:find("\\begin{document}", 1, true) or #content
  content = content:sub(1, body_start - 1) .. convert_siunitx(content:sub(body_start), units_tbl)

  -- degree sign written as ${}^{\circ}$ -> "°"
  content = replace(content, "${}^{\\circ}$", "°")

  -- no centering wrappers in figures (pandoc would make a one-cell table)
  content = sub_fn(content, find_figure, clean_figure)

  -- kableExtra/booktabs commands pandoc does not understand
  content = remove_alt(content, "\\cmidrule", { "%([^)]*%){[^}]*}", "{[^}]*}" })
  content = remove_alt(content, "\\addlinespace", { "%[[^%]]*%]", "" })
  content = unwrap_multirow(content)
  return content
end

function M.prepare(tex, opts)
  opts = opts or {}
  local render = opts.tikz or function(code, base_name)
    return M.render_tikz(code, base_name, opts.tikz_dir or vim.fn.getcwd())
  end
  tex = prepare_part(tex, opts.name or "", opts.repo or "")
  tex = preprocess(tex, render)
  return tex
end

return M
