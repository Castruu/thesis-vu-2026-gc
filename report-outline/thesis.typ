#import "/layout/thesis_template.typ": *
#import "/metadata.typ": *

#set document(title: title, author: author)

#show: thesis.with(
  abstract: include "/content/abstract.typ",
  acknowledgement: include "/content/acknowledgement.typ",
)

#include "/content/introduction.typ"
#include "/content/background.typ"
#include "/content/implementation.typ"
#include "/content/results.typ"
#include "/content/discussion.typ"
#include "/content/conclusion.typ"
