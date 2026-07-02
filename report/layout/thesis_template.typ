#import "/layout/frontmatter.typ": addfrontmatter
#import "/layout/abstract.typ": abstract as render-abstract
#import "/layout/fonts.typ": *
#import "/utils/diagram.typ": in-outline
#import "../utils/fr_qa_c.typ": const_counter, fr_counter, qa_counter

#let thesis(
  abstract: "",
  body,
) = {
  addfrontmatter()

  render-abstract(lang: "en")[#abstract]

  set page(
    margin: (left: 30mm, right: 30mm, top: 40mm, bottom: 40mm),
    numbering: none,
    number-align: center,
  )

  set text(
    font: fonts.body,
    size: 12pt,
    lang: "en",
  )

  show math.equation: set text(weight: 400)

  // --- Headings ---
  show heading: set block(below: 0.85em, above: 1.75em)
  show heading: set text(font: fonts.body)
  set heading(numbering: "1.1")
  // Reference first-level headings as "chapters"
  show ref: it => {
    let el = it.element
    if el != none and el.func() == heading and el.level == 1 {
      link(
        el.location(),
        [Chapter #numbering(el.numbering, ..counter(heading).at(el.location()))],
      )
      // Custom formatting for FR, QA, and C to remove whitespace
    } else if el != none and el.func() == figure and el.kind == "FR" {
      link(
        el.location(),
        [#el.supplement#numbering(el.numbering, ..fr_counter.at(el.location()))],
      )
    } else if el != none and el.func() == figure and el.kind == "QA" {
      link(
        el.location(),
        [#el.supplement#numbering(el.numbering, ..qa_counter.at(el.location()))],
      )
    } else if el != none and el.func() == figure and el.kind == "C" {
      link(
        el.location(),
        [#el.supplement#numbering(el.numbering, ..const_counter.at(el.location()))],
      )
    } else {
      it
    }
  }

  // --- Paragraphs ---
  set par(leading: 1em)

  // --- Citations ---
  set cite(style: "ieee")

  // --- Figures ---
  show figure: set text(size: 0.85em)

  // --- Code / pseudocode listings ---
  set raw(
    syntaxes: "../utils/pseudocode.sublime-syntax",
    theme: "../utils/pseudocode.tmTheme",
  )
  show raw.where(block: true): it => block(
    fill: luma(245),
    inset: 8pt,
    radius: 3pt,
    width: 100%,
    text(size: 9pt, it),
  )

  // --- Table of Contents ---
  show outline.entry.where(level: 1): it => {
    v(15pt, weak: true)
    strong(it)
  }
  outline(
    title: {
      text(font: fonts.body, 1.5em, weight: 700, "Contents")
      v(15mm)
    },
    indent: 2em,
  )


  v(2.4fr)
  pagebreak()


  // Main body. Reset page numbering.
  set page(numbering: "1")
  counter(page).update(1)
  set par(justify: true, first-line-indent: 2em)

  // Start each chapter on a new page
  show heading.where(level: 1): it => {
    pagebreak(weak: true)
    it
  }
  body

  // List of figures.
  pagebreak()
  heading(numbering: none)[List of Figures]
  show outline: it => {
    // Show only the short caption here
    in-outline.update(true)
    it
    in-outline.update(false)
  }
  outline(
    title: none,
    target: figure.where(kind: image),
  )

  // List of tables.
  context [
    #if query(figure.where(kind: table)).len() > 0 {
      pagebreak()
      heading(numbering: none)[List of Tables]
      outline(
        title: none,
        target: figure.where(kind: table),
      )
    }
  ]

  // Appendix.
  pagebreak()
  heading(numbering: none)[Appendix A: Supplementary Material]
  include "/layout/appendix.typ"

  pagebreak()
  heading(numbering: none)[Appendix B: Use of Generative AI Tools]
  include "/content/ai_statement.typ"

  pagebreak()
  bibliography("/thesis.yml", style: "ieee")
}
