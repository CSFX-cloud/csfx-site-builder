# csfx-site-builder

Builder image for CSFX web apps. It runs inside an isolated Firecracker microVM, clones the repository, runs the install and build commands and reports logs and the result back to the site builder service through its callback API.

Published as `ghcr.io/csfx-cloud/csfx-site-builder`.
