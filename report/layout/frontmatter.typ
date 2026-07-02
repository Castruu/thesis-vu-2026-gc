#import "/layout/fonts.typ": *
#import "/metadata.typ": author, authorId, degree, program, readerSecond, supervisorFirst, title

#let addfrontmatter() = {
  set page(
    numbering: none,
    number-align: center,
    margin: (left: 30mm, right: 30mm, top: 40mm, bottom: 40mm),
  )
  set text(font: fonts.body, size: 11pt, lang: "en")

  let degree-name = if degree == "Master" { "Master of Science" } else { "Bachelor of Science" }

  align(center, image("/resources/vua.pdf", width: 35%))

  v(1fr)

  align(center, text(size: 12pt, degree + " Thesis"))

  v(2em)

  line(length: 100%, stroke: 0.5pt)
  v(0.6em)
  align(center, text(size: 18pt, weight: "bold", title))
  v(0.6em)
  line(length: 100%, stroke: 0.5pt)

  v(2em)

  align(center, text(size: 12pt)[by])
  v(0.8em)
  align(center, text(size: 14pt, weight: "bold", author))
  v(0.3em)
  align(center, text(size: 12pt, "(" + authorId + ")"))

  v(1fr)

  align(center, grid(
    columns: 2,
    row-gutter: 0.3em,
    column-gutter: 0.5em,
    align: (left, left),
    emph[First supervisor:], supervisorFirst,
    emph[Second reader:], readerSecond,
  ))

  v(1fr)

  align(center, emph(text(
    size: 11pt,
    "Submitted in fulfillment of the requirements for"
      + linebreak()
      + "the VU "
      + degree-name
      + " degree in "
      + program,
  )))

  v(1em)
  v(1fr)

  align(center, text(size: 11pt, datetime.today().display("[month repr:long] [day padding:none], [year]")))

  pagebreak()
}
