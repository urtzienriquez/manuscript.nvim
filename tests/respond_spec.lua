-- tests/respond_spec.lua: the response to the reviewers, from their comments.
local respond = require("manuscript.respond")

describe("the reviewers' comments", function()
  it("split by reviewer and by their numbers; the text of a point over lines and paragraphs", function()
    local letter = table.concat({
      "Dear Dr Author, thank you for your submission.",
      "",
      "Reviewer #1:",
      "1. The methods are unclear",
      "about the sites.",
      "2) Figure 2 needs a scale bar (50% larger).",
      "",
      "Its legend is too small.",
      "Comments of Reviewer 2",
      "(1) Cite Smith & Jones.",
      "- And a bullet.",
    }, "\n")
    local reviews = respond.split(letter)
    assert.equals(2, #reviews) -- (the letter before the first reviewer: no comment to answer)
    assert.equals("Reviewer #1", reviews[1].reviewer)
    assert.same({ id = "1", text = "The methods are unclear about the sites." }, reviews[1].points[1])
    assert.same({ id = "2", text = "Figure 2 needs a scale bar (50% larger).\n\nIts legend is too small." }, reviews[1].points[2])
    assert.equals("Comments of Reviewer 2", reviews[2].reviewer)
    assert.same({ "1", "2" }, vim.tbl_map(function(p) return p.id end, reviews[2].points))
    -- without reviewers named: all of it, the first lines too
    assert.equals("Fix the title.", respond.split("1. Fix the title.\n2. And the abstract.")[1].points[1].text)
  end)

  it("without numbers: each paragraph a point; in the document, quoted and escaped, numbered by reviewer", function()
    local reviews = respond.split("Referee 1\n\nFirst remark,\non two lines.\n\nSecond remark: 50% & $5.\n")
    assert.equals(2, #reviews[1].points)
    assert.equals("First remark, on two lines.", reviews[1].points[1].text)
    local tex = respond.document(reviews, ".build/paper/paper")
    assert.truthy(tex:find("\\subsection*{1.2}", 1, true))
    assert.truthy(tex:find("Second remark: 50\\% \\& \\$5.", 1, true))
    assert.truthy(tex:find("\\externaldocument[ms-]{.build/paper/paper}", 1, true))
  end)
end)
