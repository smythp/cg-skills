#!/bin/sh
# preflight.sh — check that the environment can run a build-verified
# Dockerfile migration. Prints findings; writes nothing; changes nothing.
#
# Usage: preflight.sh [BUILD_CONTEXT_DIR]
#   BUILD_CONTEXT_DIR  the directory that will be sent to docker build
#                      (default: current directory)
#
# Exit codes: 0 = required tools present (docker daemon, chainctl login and
# a working organization listing, timeout, and the parsing tools awk, grep,
# sed, sort); 1 = a required tool is missing or not working. Optional
# findings (syft, .dockerignore) are reported but never fail the check.

set -u

CONTEXT="${1:-.}"
fail=0

# Sandboxes commonly drop /usr/local/bin from PATH; chainctl and syft often
# live there. Extending PATH here affects only this process.
case ":$PATH:" in
  *:/usr/local/bin:*) : ;;
  *) PATH="/usr/local/bin:$PATH"; export PATH ;;
esac

echo "== preflight: required =="

# This script parses the organization listing with these tools; if one is
# missing, the parsing would silently produce nothing and a real organization
# would read as "no organizations", steering an entitled customer to the
# public catalog. Check them before anything parses.
missing_parsers=""
for t in awk grep sed sort; do
  command -v "$t" >/dev/null 2>&1 || missing_parsers="$missing_parsers $t"
done
if [ -z "$missing_parsers" ]; then
  echo "awk/grep/sed/sort: OK"
else
  echo "awk/grep/sed/sort: MISSING:$missing_parsers — preflight parses the organization listing with these; without them the listing cannot be read and an entitled organization would wrongly read as 'no organizations'."
  fail=1
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    echo "docker: OK ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'version unknown'))"
  else
    echo "docker: CLI present but the Docker daemon is not reachable. Builds are required for verification; start the Docker daemon and rerun preflight."
    fail=1
  fi
else
  echo "docker: NOT FOUND. This skill needs Docker to build and verify. Install instructions for the user: https://docs.docker.com/get-docker/"
  fail=1
fi

if command -v chainctl >/dev/null 2>&1; then
  if chainctl auth status >/dev/null 2>&1; then
    ident=$(chainctl auth status 2>/dev/null | awk -F'|' '/Email/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
    echo "chainctl: OK (logged in${ident:+ as $ident})"
    # The listing runs alone so its exit status is visible: in a pipeline it
    # would be swallowed (no pipefail in POSIX sh), and an API or network
    # failure would read as "no organizations" — silently steering an
    # entitled customer to the public catalog.
    orgs_json=$(chainctl iam organizations list -o json 2>/dev/null)
    orgs_rc=$?
    if [ "$orgs_rc" -ne 0 ]; then
      echo "organizations: LISTING FAILED (chainctl iam organizations list exited $orgs_rc). This is an API or network error, not 'no organizations'; without the real list, an entitled organization would be migrated onto the public catalog. Fix connectivity or auth and rerun."
      fail=1
    else
      # An exit 0 with empty or non-JSON output is the same failure in
      # different clothes: parsed, it yields nothing, and nothing reads as
      # "no organizations". Accept only output whose first non-whitespace
      # character starts a JSON document.
      first_char=$(printf '%s\n' "$orgs_json" | awk 'NF { print substr($1, 1, 1); exit }')
      case "$first_char" in
        '['|'{')
          orgs=$(printf '%s\n' "$orgs_json" | grep -o '"name"[^,}]*' | sed 's/.*: *"//; s/"$//' | sort -u)
          if [ -n "$orgs" ]; then
            echo "organizations visible to this identity:"
            echo "$orgs" | sed 's/^/  /'
          else
            echo "organizations: none visible (public catalog cgr.dev/chainguard will be the default)"
          fi
          ;;
        *)
          echo "organizations: LISTING FAILED (chainctl iam organizations list exited 0 but its output was empty or not JSON). This is an API or client error, not 'no organizations'; without the real list, an entitled organization would be migrated onto the public catalog. Fix chainctl or connectivity and rerun."
          fail=1
          ;;
      esac
    fi
  else
    echo "chainctl: present but not logged in. The user runs: chainctl auth login (interactive; it opens a browser)."
    fail=1
  fi
else
  echo "chainctl: NOT FOUND. Tag, digest, and org lookups need it. Install instructions for the user: https://edu.chainguard.dev/platform/chainctl-usage/how-to-install-chainctl/"
  fail=1
fi

if command -v timeout >/dev/null 2>&1; then
  echo "timeout: OK"
else
  echo "timeout: NOT FOUND (GNU coreutils or BusyBox provide it). The lookup and comparison scripts refuse to run docker without it — an unbounded pull or scan can hang the migration indefinitely."
  fail=1
fi

echo ""
echo "== preflight: optional =="

if command -v syft >/dev/null 2>&1; then
  echo "syft: OK ($(syft version 2>/dev/null | awk '/^Version:/ {print $2}'))"
else
  echo "syft: not installed; compare-images.sh will fall back to its pinned scanner container (docker.io/anchore/syft, pinned by digest in the script). Install instructions if the user wants the binary: https://github.com/anchore/syft#installation"
fi

if [ -f "$CONTEXT/.dockerignore" ]; then
  echo ".dockerignore: present in $CONTEXT"
else
  echo ".dockerignore: MISSING in $CONTEXT — Docker will include this entire directory in the build; check for secrets and large files before the first build"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "preflight: PASS"
else
  echo "preflight: FAIL — fix the items above before migrating"
fi
exit "$fail"
