#!/bin/bash
# Run a build command, keep its full log, and turn a failure into an
# annotation on the run page.
#
# WHY: the job log needs a GitHub sign-in to read, so a failure seen from a
# phone (or by anyone without repo access) is just "exit code 1". Annotations
# are public on the run page, so the tail of the log goes into one.
#
# usage: scripts/ci-run-logged.sh <name> <command...>
#   the log lands in $RUNNER_TEMP/<name>.log and is uploaded by the workflow.

set -u

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <name> <command...>" >&2
    exit 2
fi

name=$1
shift
log="${RUNNER_TEMP:-/tmp}/${name}.log"

set -o pipefail
"$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}

if [ "$rc" -ne 0 ]; then
    # One annotation, newlines percent-encoded as the workflow command format
    # requires. 25 lines is enough to carry a compiler error and its context.
    tail=$(tail -n 25 "$log" 2>/dev/null | awk '
        { gsub(/%/, "%25"); gsub(/\r/, ""); printf "%s%%0A", $0 }
    ')
    echo "::error::${name} failed (exit ${rc}). Last lines of ${log}: ${tail}"
    exit "$rc"
fi
