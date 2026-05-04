#!/usr/bin/env bash
# RC1 reproduction harness — release source resolution has no version comparison.
#
# Asserts the post-fix invariant:
#   download_and_install.ps1 must compare the S3-published version against
#   the GitHub-published version (or otherwise fall through to GitHub when
#   GitHub holds a newer release) before settling on the release source.
#
# Pre-fix HEAD: this assertion fails RED — the script unconditionally
# locks in S3 the moment $S3LatestPayload.version is non-empty.
#
# Post-fix HEAD: a code path exists that consults GitHub's latest release
# AND compares against the S3 version (or supersedes it) before binding.

set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/download_and_install.ps1"

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not found" >&2
  exit 2
fi

# Heuristic: the fixed script will reference both the S3 version field
# AND a GitHub-side version (tag_name or releases endpoint) in the SAME
# resolution region — i.e. between "Resolve release source" and the
# GitHub fallback gate. The pre-fix script only references S3 there.
START="$(grep -n 'Resolve release source' "$SCRIPT" | head -1 | cut -d: -f1)"
END="$(grep -n 'GitHub fallback (or primary' "$SCRIPT" | head -1 | cut -d: -f1)"

if [ -z "$START" ] || [ -z "$END" ]; then
  echo "FAIL: anchors moved; cannot locate resolution region. Update harness." >&2
  exit 2
fi

REGION="$(sed -n "${START},${END}p" "$SCRIPT")"

GH_REFS=$(printf '%s\n' "$REGION" | grep -cE 'tag_name|/releases/latest|api\.github\.com.*releases|GITHUB_API.*releases' || true)
COMPARE_REFS=$(printf '%s\n' "$REGION" | grep -cE '\[version\]::|System\.Version|Compare-RfqVersion|VersionGreater|version.*>.*version|newer.*than|stale|prefer.*github' || true)

echo "GitHub release references in resolution region: $GH_REFS"
echo "Version-comparison references in resolution region: $COMPARE_REFS"

if [ "$GH_REFS" -ge 1 ] && [ "$COMPARE_REFS" -ge 1 ]; then
  echo "PASS: resolution region consults GitHub AND performs version comparison."
  exit 0
fi

echo "FAIL: resolution region does not compare against GitHub before binding to S3."
echo "      S3 returning ANY non-empty version short-circuits the GitHub fallback."
echo "      Reference: download_and_install.ps1:758-796"
exit 1
