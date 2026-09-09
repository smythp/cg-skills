#!/bin/sh
# preflight.sh — check that the environment can run a build-verified
# Dockerfile migration. Prints findings; writes nothing; changes nothing.
#
# Usage: preflight.sh [BUILD_CONTEXT_DIR]
#   BUILD_CONTEXT_DIR  the directory that will be sent to docker build
#                      (default: current directory)
#
# Exit codes: 0 = required tools present (docker daemon + chainctl login);
# 1 = a required tool is missing or not working. Optional findings (syft,
# dfc, .dockerignore) are reported but never fail the check.

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
    orgs=$(chainctl iam organizations list -o json 2>/dev/null | grep -o '"name"[^,}]*' | sed 's/.*: *"//; s/"$//' | sort -u)
    if [ -n "$orgs" ]; then
      echo "organizations visible to this identity:"
      echo "$orgs" | sed 's/^/  /'
    else
      echo "organizations: none visible (public catalog cgr.dev/chainguard will be the default)"
    fi
  else
    echo "chainctl: present but not logged in. Run: chainctl auth login"
    fail=1
  fi
else
  echo "chainctl: NOT FOUND. Install it (https://edu.chainguard.dev/chainguard/chainctl/) — tag, digest, and org lookups need it."
  fail=1
fi

echo ""
echo "== preflight: optional =="

if command -v syft >/dev/null 2>&1; then
  echo "syft: OK ($(syft version 2>/dev/null | awk '/^Version:/ {print $2}'))"
else
  echo "syft: not installed; compare-images.sh will fall back to a syft container (needs to pull cgr.dev/chainguard/syft)"
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
