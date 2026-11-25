-- tests/latex_spec.lua: a submission's source: switches resolved in the text, comments out.
local latex = require("manuscript.latex")

describe("switches resolved in the text", function()
  it("keeps only the branch of the variant, nested ones and spacing as TeX reads them", function()
    local src = "A \\ifanonymous Withheld.\\else By Ana.\\fi\\ B"
    assert.equals("A Withheld.\\ B", latex.resolve(src, { anonymous = true }))
    assert.equals("A By Ana.\\ B", latex.resolve(src, { anonymous = false }))
    -- a block over lines: no lines left where it was
    local block = "\\title{T}\n\\ifanonymous\n\\else\n\\author{Ana}\n\\affil{Uni}\n\\fi\n\\begin{document}\n"
    assert.equals("\\title{T}\n\\begin{document}\n", latex.resolve(block, { anonymous = true }))
    assert.equals("\\title{T}\n\\author{Ana}\n\\affil{Uni}\n\\begin{document}\n", latex.resolve(block, { anonymous = false }))
    -- conditionals inside a branch (TeX's, \newif's) keep their own \else and \fi
    local nested = "\\newif\\ifdraft\n\\ifanonymous X\\ifdraft D\\else F\\fi Y\\else\\ifnum1=1 N\\fi\\fi Z"
    assert.equals("\\newif\\ifdraft\nX\\ifdraft D\\else F\\fi YZ", latex.resolve(nested, { anonymous = true }))
    -- (\fi then Z: a space between, not \fiZ)
    assert.equals("\\newif\\ifdraft\n\\ifnum1=1 N\\fi Z", latex.resolve(nested, { anonymous = false }))
    -- switches inside switches; no \else
    assert.equals("ab", latex.resolve("a\\ifanonymous\\iflinenumbers b\\fi\\fi", { anonymous = true, linenumbers = true }))
    assert.equals("a", latex.resolve("a\\ifanonymous\\iflinenumbers b\\fi\\fi", { anonymous = true, linenumbers = false }))
  end)

  it("leaves definitions, guards, other conditionals and unbalanced ones as they are", function()
    local guard = "\\ifcsname ifanonymous\\endcsname\\else\\expandafter\\newif\\csname ifanonymous\\endcsname\\fi"
    assert.equals(guard, latex.resolve(guard, { anonymous = true }))
    assert.equals("\\newif\\ifanonymous \\anonymoustrue", latex.resolve("\\newif\\ifanonymous \\anonymoustrue", { anonymous = true }))
    assert.equals("\\ifdraft x\\fi", latex.resolve("\\ifdraft x\\fi", { anonymous = true }))
    assert.equals("\\ifanonymousx y", latex.resolve("\\ifanonymousx y", { anonymous = true })) -- (another name)
    assert.equals("\\ifanonymous never closed", latex.resolve("\\ifanonymous never closed", { anonymous = true }))
    assert.equals("$a \\iff b$", latex.resolve("$a \\iff b$", { anonymous = true }))
  end)
end)

describe("comments out", function()
  it("as TeX reads them: comment lines go, an end-of-line comment takes the line end", function()
    assert.equals("a\nb\n", latex.strip_comments("a\n% a comment by Ana\nb\n"))
    assert.equals("a\nb\n", latex.strip_comments("a\n   % indented\nb\n"))
    assert.equals("textjoined\n", latex.strip_comments("text% no space\n   joined\n"))
    assert.equals("\\relax joined\n", latex.strip_comments("\\relax%\n   joined\n")) -- (not \relaxjoined)
    assert.equals("50\\% of them\n", latex.strip_comments("50\\% of them\n"))
    assert.equals("x\\\\\ny\n", latex.strip_comments("x\\\\% after a line break\n\ny\n"):gsub("\n\n", "\n"))
  end)

  it("keeps a % in URLs and verbatim environments", function()
    local src = "\\url{https://a.org/b%20c} and \\href{https://x.org/%7E}{site}\n"
    assert.equals(src, latex.strip_comments(src))
    local verb = "\\begin{verbatim}\n50% kept\n\\end{verbatim}\n"
    assert.equals(verb, latex.strip_comments(verb))
  end)
end)

describe("a submission's search for its authors", function()
  it("skips the keys of citations (a key names an author)", function()
    local without = require("manuscript.submit").without_keys
    assert.equals("see \\textcite{} and \\parencite[p.~2][]{}, by Lourdais.",
      without("see \\textcite{lourdais2004} and \\parencite[p.~2][]{lourdais2004,smith}, by Lourdais."))
    assert.equals("\\Citeauthor*{} \\nocite{}", without("\\Citeauthor*{ana2020} \\nocite{x}"))
  end)
end)

describe("a submission's search for its authors: a match", function()
  local has = require("manuscript.submit").has
  it("of a name is a whole word with its capitals; of a phrase or an email, in any case", function()
    assert.is_true(has("by Ana Author.", "Ana"))
    assert.is_false(has("the analysis", "Ana"))
    assert.is_false(has("\\author{}", "Author"))
    assert.is_true(has("Martínez-Freiría (2009)", "Martínez-Freiría"))
    assert.is_false(has("Martínez-Freiríaxx", "Martínez-Freiría"))
    assert.is_true(has("see ANA AUTHOR here", "Ana Author"))
    assert.is_true(has("mail: ANA@UNI.EXAMPLE", "ana@uni.example"))
  end)
end)
