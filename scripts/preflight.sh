#!/bin/sh
# preflight.sh — check that the environment can run a build-verified
# Dockerfile migration. Prints findings; writes nothing; changes nothing.
#
# Usage: preflight.sh [BUILD_CONTEXT_DIR]
#   BUILD_CONTEXT_DIR  the directory that will be sent to docker build
#                      (default: current directory)
#
# Exit codes: 0 = required tools present (docker daemon, chainctl login and
# a working organization listing, timeout); 1 = a required tool is missing or
# not working. Optional findings (syft, dfc, .dockerignore) are reported but
# never fail the check.

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

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    echo "docker: OK ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'version unknown'))"
  else
    echo "docker: CLI present but the daemon is not reachable. Without builds there is no verification, and an unverified migration is the failure this skill exists to prevent."
    fail=1
  fi
else
  echo "docker: NOT FOUND. This skill needs Docker; for a rules-only rewrite without builds, use a static migration skill instead."
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
      orgs=$(printf '%s\n' "$orgs_json" | grep -o '"name"[^,}]*' | sed 's/.*: *"//; s/"$//' | sort -u)
      if [ -n "$orgs" ]; then
        echo "organizations visible to this identity:"
        echo "$orgs" | sed 's/^/  /'
      else
        echo "organizations: none visible (public catalog cgr.dev/chainguard will be the default)"
      fi
    fi
  else
    echo "chainctl: present but not logged in. Run: chainctl auth login"
    fail=1
  fi
else
  echo "chainctl: NOT FOUND. Install it (https://edu.chainguard.dev/chainguard/chainctl/) — tag, digest, and org lookups need it."
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
  echo "syft: not installed; compare-images.sh will fall back to its pinned scanner container (docker.io/anchore/syft, pinned by digest in the script)"
fi

if command -v dfc >/dev/null 2>&1; then
  echo "dfc: OK (optional deterministic first draft is available)"
else
  echo "dfc: not installed (fine — the draft step is optional)"
fi

if [ -f "$CONTEXT/.dockerignore" ]; then
  echo ".dockerignore: present in $CONTEXT"
else
  echo ".dockerignore: MISSING in $CONTEXT — docker build ships this entire directory to the daemon; check for secrets and large files before the first build"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "preflight: PASS"
else
  echo "preflight: FAIL — fix the items above before migrating"
fi
exit "$fail"
