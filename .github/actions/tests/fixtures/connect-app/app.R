library(shiny)

# websocket pulls AsioHeaders via LinkingTo, which a binary install prunes. It
# makes this fixture exercise the PKG_INCLUDE_LINKINGTO path that keeps
# writeManifest's renv snapshot from aborting on the missing header package.
library(websocket)

ui <- fluidPage(
  titlePanel("connect-deploy smoke fixture"),
  verbatimTextOutput("info")
)

server <- function(input, output, session) {
  output$info <- renderPrint(
    # jsonlite is a Suggests dep on a graceful-degradation path. Because the
    # app's own code names it, writeManifest() records it, so Connect receives
    # it — the deploy-optional case check-suggests enforces.
    if (requireNamespace("jsonlite", quietly = TRUE)) {
      jsonlite::toJSON(list(ok = TRUE), auto_unbox = TRUE)
    } else {
      "jsonlite not available"
    }
  )
}

shinyApp(ui, server)
