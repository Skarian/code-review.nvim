#!/usr/bin/env sh
set -eu

claude -p "Review this repository against docs/PRD.md and docs/VALIDATION.md. Report concrete blockers only. Do not edit files."
