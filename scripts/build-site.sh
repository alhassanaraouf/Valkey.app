#!/usr/bin/env bash
# Builds the valkey.app website into _site/ (served by Cloudflare Workers static assets, see wrangler.jsonc).
# Used by Cloudflare Workers Builds (build command) and by the Deploy website CI check.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf _site
mkdir _site
cp -R website/. _site/
cp registry/registry.json registry/registry.json.sig _site/
# Versions, modules and FAQ answers as plain HTML (crawlers don't run JavaScript), plus sitemap.xml.
python3 website/render.py registry/registry.json _site
rm _site/render.py _site/og-image.svg
