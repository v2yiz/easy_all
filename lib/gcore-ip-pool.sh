#!/usr/bin/env bash

# Source-tree migration tombstone for launchers installed before Gcore removal.
# Current launchers never source or install this file.
#
# It must stay in the source tree even though nothing references it: a launcher
# installed before d067a2b still validates the freshly cloned tree against its own
# baked-in manifest, which lists this path. Removing the file makes `self-update`
# fail on such an install with "下载的 easy_all 项目不完整". It is intentionally
# absent from runtime.manifest so it is never installed at runtime.
