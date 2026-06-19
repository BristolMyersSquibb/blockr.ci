# Scan-only manifest helper, never executed by Connect (it runs the app, not
# loose scripts). glue is a Suggests dep the app never names in its own code,
# so writeManifest()'s scanner would drop it from the manifest. Naming it in a
# top-level file the scanner reads forces it in, so Connect receives it. This
# is rsconnect's documented pattern for deps that code-scanning can't see.
requireNamespace("glue")
