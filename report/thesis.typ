#import "/layout/thesis_template.typ": *
#import "/metadata.typ": *

#set document(title: title, author: author)

#show: thesis.with(
  abstract: include "/content/abstract.typ",
  acknowledgement: include "/content/acknowledgement.typ",
)

#include "/content/introduction.typ"
#include "/content/background.typ"
#include "/content/related_work.typ"
#include "/content/requirements.typ"
#include "/content/system_design.typ"
#include "/content/evaluation.typ"
#include "/content/summary.typ"
