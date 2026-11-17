#!/usr/bin/env bash
# Render a PNG twin of every SVG under assets/ into a built site directory.
#
# Why: assets/feed.xml rewrites .svg image links to .png, because Dev.to (and
# many feed readers) don't render SVG. The blog pages keep the SVGs; only the
# feed points at the PNGs. The deploy workflow runs this after `jekyll build`,
# so PNGs are never committed and every new post's SVGs get twins automatically.
#
# Usage: tools/svg2png.sh <site_dir>     (e.g. _site)
# Needs: rsvg-convert (apt: librsvg2-bin, brew: librsvg). The SVGs use a system
# font stack, so install a matching sans font where it runs (CI: fonts-roboto).
set -euo pipefail

site_dir="${1:?usage: tools/svg2png.sh <site_dir>}"
command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found (librsvg2-bin / librsvg)" >&2; exit 1; }

count=0
while IFS= read -r -d '' svg; do
  out="$site_dir/${svg%.svg}.png"
  mkdir -p "$(dirname "$out")"
  # 2x of the SVG's own size; white background so dark-mode readers don't put
  # dark text on a dark page.
  rsvg-convert --zoom 2 --background-color white --output "$out" "$svg"
  count=$((count + 1))
done < <(find assets -name '*.svg' -print0)

echo "svg2png: rendered $count PNG twin(s) into $site_dir"
