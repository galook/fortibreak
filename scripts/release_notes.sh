#!/bin/bash
# Print release notes for VERSION: its CHANGELOG.md section, install steps, then the commits since the previous tag.
set -euo pipefail
cd "$(dirname "$0")/.."
version="$1"
minimum="${2:-}"
repository="${GITHUB_REPOSITORY:-galook/fortibreak}"

section="$(awk -v heading="## [$version]" '
  /^## \[/ { if (found) exit; if (index($0, heading) == 1) { found = 1; next } }
  found' CHANGELOG.md)"
if [ -n "${section//[[:space:]]/}" ]; then
  printf '%s\n' "$section"
else
  printf 'No CHANGELOG.md entry for %s.\n' "$version"
fi

cat <<EOF

### Install

Requires an Apple Silicon Mac${minimum:+ with macOS $minimum or newer}. FortiBreak is ad-hoc signed, not notarized.

1. Download \`FortiBreak-$version.zip\`, unzip it and move \`FortiBreak.app\` to Applications.
2. Clear the download quarantine so macOS lets it open:
   \`\`\`
   xattr -dr com.apple.quarantine /Applications/FortiBreak.app
   \`\`\`
3. Open FortiBreak and click **Enable VPN helper** once (macOS asks for an administrator password).

Each new version needs the helper approved again.
EOF

previous="$(git describe --tags --abbrev=0 "v$version^" 2>/dev/null || true)"
printf '\n### Commits\n\n'
git log --no-merges --format='- %s (%h)' "${previous:+$previous..}v$version"
if [ -n "$previous" ]; then
  printf '\n**Full diff:** https://github.com/%s/compare/%s...v%s\n' "$repository" "$previous" "$version"
fi
