-- Expected values were produced by the Python scripts (prepare.py, then
-- preprocess.py) that prepare.lua ports.
local prepare = require("manuscript.prepare")

local function run(tex, name)
  return prepare.prepare(tex, { name = name, repo = "/REPO", tikz = function(_, base) return base .. ".svg" end })
end

describe("manuscript.prepare", function()
  describe("siunitx", function()
    it("converts \\SI, \\qty and \\si in text mode", function()
      local tex = "\\begin{document}\nIt was \\SI{20}{\\celsius}, \\qty{-3.5}{\\milli\\gram\\per\\hour}, \\si{\\kilo\\metre\\squared} and \\si{\\metre\\per\\second\\squared}.\n\\end{document}\n"
      local want = "\\begin{document}\nIt was 20~\194\176C, \226\136\1463.5~mg\\,h\\textsuperscript{\226\136\1461}, km\\textsuperscript{2} and m\\,s\\textsuperscript{\226\136\1462}.\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
    it("uses \\mathrm in math mode", function()
      local tex = "\\begin{document}\n$x = \\SI{5}{\\micro\\metre\\cubed}$, \\(\\si{\\per\\year}\\), \\begin{equation}\\qty{2}{\\kilo\\gram}\\end{equation}, $$\\ang{30}$$\n\\end{document}\n"
      local want = "\\begin{document}\n$x = 5\\,\\mathrm{\194\181m}^{3}$, \\(\\mathrm{year}^{-1}\\), \\begin{equation}2\\,\\mathrm{kg}\\end{equation}, $$30^{\\circ}$$\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
    it("honours \\DeclareSIUnit and formats \\num, \\ang and unknown units", function()
      local tex = "\\DeclareSIUnit{\\eggs}{eggs}\n\\DeclareSIUnit[mode=text]{\\ind}{ind.}\n\\begin{document}\n\\SI{12}{\\eggs\\per\\ind}, \\num{-1.5}, \\num{ 42 }, \\ang{45}, \\si{\\unknown} % \\SI{1}{\\metre}\n\\end{document}\n"
      local want = "\\DeclareSIUnit{\\eggs}{eggs}\n\\DeclareSIUnit[mode=text]{\\ind}{ind.}\n\\begin{document}\n12~eggs\\,ind.\\textsuperscript{\226\136\1461}, \226\136\1461.5, 42, 45\194\176, unknown % \\SI{1}{\\metre}\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
    it("leaves the preamble alone", function()
      local tex = "\\newcommand{\\x}{\\SI{1}{\\metre}}\n\\begin{document}\n\\SI[round-mode=places]{1}{\\metre}\n\\end{document}\n"
      local want = "\\newcommand{\\x}{\\SI{1}{\\metre}}\n\\begin{document}\n1~m\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
  end)
  describe("authblk", function()
    it("builds the author and affiliation block (three authors)", function()
      local tex = "\\usepackage{authblk}\n\\title{A study}\n\\author[1]{Ann Lee}\n\\author[2*]{Bo Ng}\n\\author[1,2]{Cy Ruiz}\n\\affil[1]{Uni A}\n\\affil[2]{Inst B}\n\\date{\\today}\n\\begin{document}\n\\maketitle\nText.\n\\end{document}\n"
      local want = "\\title{A study}\n\\begin{document}\n\\maketitle\n\n\\begin{center}Ann Lee\\textsuperscript{1}, Bo Ng\\textsuperscript{2*} \\& Cy Ruiz\\textsuperscript{1,2}\\end{center}\n\\begin{flushleft}\\textsuperscript{1} Uni A\\\\\\textsuperscript{2} Inst B\\end{flushleft}\n\n\\vspace{1em}\nText.\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
    it("joins two authors with 'and'", function()
      local tex = "\\usepackage{authblk}\n\\author[1]{Ann Lee}\n\\author[2]{Bo Ng}\n\\affil[1]{Uni A}\n\\affil[2]{Inst B}\n\\begin{document}\n\\maketitle\n\\end{document}\n"
      local want = "\\begin{document}\n\\maketitle\n\n\\begin{center}Ann Lee\\textsuperscript{1} and Bo Ng\\textsuperscript{2}\\end{center}\n\\begin{flushleft}\\textsuperscript{1} Uni A\\\\\\textsuperscript{2} Inst B\\end{flushleft}\n\n\\vspace{1em}\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
  end)
  describe("tables", function()
    it("unwraps \\resizebox and \\multirow", function()
      local tex = "\\begin{document}\n\\resizebox{\\textwidth}{!}{\\begin{tabular}{ll}\n\\multirow{2}{*}{Group {A}} & a \\\\\n\\multirow{3}{4cm}[2pt]{Other} & b\\\\\n\\cmidrule(lr){1-2}\\addlinespace[2pt]\n\\end{tabular}}\n\\end{document}\n"
      local want = "\\begin{document}\n\\begin{tabular}{ll}\nGroup {A} & a \\\\\nOther & b\\\\\n\n\\end{tabular}\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
    it("flattens one-column tabulars, \\shortstack and the first head", function()
      local tex = "\\begin{document}\n\\begin{tabular}[t]{@{}l@{}}a\\\\b\\end{tabular} \\shortstack[l]{c\\\\d {e}}\n\\endfirsthead\nhead\n\\endhead\nrow\n\\end{document}\n"
      local want = "\\begin{document}\na b c d {e}\n\\endhead\nrow\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
  end)
  describe("knitr", function()
    it("turns alltt into verbatim and strips \\hl commands", function()
      local tex = "\\begin{document}\n\\begin{knitrout}\n\\definecolor{shadecolor}{rgb}{0.97, 0.97, 0.97}\\color{fgcolor}\\begin{kframe}\n\\begin{alltt}\n\\hlkwd{library}(\\hlstd{x}) \\hlcom{# \\{a\\}}\n\\end{alltt}\n\\end{kframe}\n\\end{knitrout}\n\\end{document}\n"
      local want = "\\begin{document}\n\n\n\\begin{verbatim}\nlibrary(x) # {a}\n\\end{verbatim}\n\n\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
    it("turns Shaded/Highlighting into verbatim", function()
      local tex = "\\begin{document}\n\\begin{Shaded}\n\\begin{Highlighting}[]\n\\FunctionTok{f}\\NormalTok{(x)}\n\n\\end{Highlighting}\n\\end{Shaded}\n\\end{document}\n"
      local want = "\\begin{document}\n\\begin{verbatim}\\FunctionTok{f}\\NormalTok{(x)}\\end{verbatim}\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
  end)
  describe("appendix", function()
    it("expands \\appendixtitleblock", function()
      local tex = "\\title{My Paper}\n\\author{A. B.}\n\\author{C. D.}\n\\begin{document}\n\\appendixtitleblock{2}\n  \\label{app:two}\nBody\n\\end{document}\n"
      local want = "\\title{My Paper}\n\\author{A. B.}\n\\author{C. D.}\n\\begin{document}\n\\begin{center}\n{\\Large\\textbf{Appendix 2} \\textit{for:} My Paper}\n\n{\\large A. B.; C. D.}\n\\end{center}\n\n\\label{app:two}\nBody\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
    it("turns the appendix start into a marker", function()
      local tex = "\\title{My Paper}\n\\begin{document}\nText.\n\\clearpage\n\\nolinenumbers\n\\section*{Appendix}\n\\renewcommand{\\thesection}{S3.\\arabic{section}}\n\\renewcommand{\\thefigure}{S3.\\arabic{figure}}\n\\renewcommand{\\thetable}{S3.\\arabic{table}}\n\\appendixtitleblock{3}\\label{app:three}\nBody\n\\end{document}\n"
      local want = "\\title{My Paper}\n\\begin{document}\nText.\n\n\nTOWORDAPPENDIX:3:appendix3\n\n\n\\begin{center}\n{\\Large\\textbf{Appendix 3} \\textit{for:} My Paper}\n\n{\\large }\n\\end{center}\n\n\\label{app:three}\nBody\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
    it("strips title lines in appendix parts", function()
      local tex = "\\title{T}\n\\author[1]{A}\n\\affil[1]{Inst}\n\\author{Kept} too\n\\title{x\n\\begin{document}\n\\maketitle\nx\n\\end{document}\n"
      local want = "\\author{Kept} too\n\\title{x\n\\begin{document}\n\\maketitle\nx\n\\end{document}\n"
      assert.are.equal(want, run(tex, "appendix1"))
    end)
    it("keeps title lines in other parts", function()
      local tex = "\\title{T}\n\\author{A}\n\\begin{document}\n\\appendixtitleblock{1}\\label{app:one}\n\\end{document}\n"
      local want = "\\title{T}\n\\author{A}\n\\begin{document}\n\\begin{center}\n{\\Large\\textbf{Appendix 1} \\textit{for:} T}\n\n{\\large A}\n\\end{center}\n\n\\label{app:one}\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
  end)
  describe("misc", function()
    it("replaces $-$, the degree sign and figure paths", function()
      local tex = "\\begin{document}\nvalue $-$3, $x$, 20${}^{\\circ}$C, \\includegraphics{../figures/a.pdf}\n\\end{document}\n"
      local want = "\\begin{document}\nvalue \226\136\1463, $x$, 20\194\176C, \\includegraphics{/REPO/figures/a.pdf}\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
    it("drops centering in figures, fixes citations and bibliography", function()
      local tex = "\\begin{document}\n\\begin{figure}\n\\centering\n\\begin{center}x\\end{center}\n\\end{figure}\n\\centering\n\\nptextcite{k}\n\\printbibliography[heading=bibnumbered, title={References}]\n\\end{document}\n"
      local want = "\\begin{document}\n\\begin{figure}\n\nx\n\\end{figure}\n\\centering\n\\textcite{k}\n\\section{References}\n\\printbibliography[heading=none]\n\\end{document}\n"
      assert.are.equal(want, run(tex, "main"))
    end)
  end)
  describe("tikz", function()
    it("names pictures by figure label or sha1 and passes a standalone document", function()
      local tex = "\\begin{document}\n\\begin{figure}\n\\begin{tikzpicture}\\draw (0,0) -- (1,1);\\end{tikzpicture}\n\\label{fig:my plot}\n\\end{figure}\n\\begin{tikzpicture}\\node {a};\\end{tikzpicture}\n\\end{document}\n"
      local seen = {}
      local got = prepare.prepare(tex, { name = "main", repo = "/REPO", tikz = function(code, base)
        seen[#seen + 1] = { code = code, base = base }
        return base .. ".svg"
      end })
      assert.are.equal("\\begin{document}\n\\begin{figure}\n\\includegraphics[width=\\textwidth]{tikz_my_plot.svg}\n\\label{fig:my plot}\n\\end{figure}\n\\includegraphics[width=\\textwidth]{tikz_eaa2806f1ef40fad.svg}\n\\end{document}\n", got)
      assert.are.equal(2, #seen)
      assert.truthy(seen[1].code:find("\\documentclass{standalone}", 1, true))
      assert.truthy(seen[1].code:find("\\begin{tikzpicture}\\node {a};\\end{tikzpicture}", 1, true))
    end)
  end)
end)
