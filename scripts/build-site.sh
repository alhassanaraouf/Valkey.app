#!/usr/bin/env bash
# Builds the valkey.app website into _site/ (served by Cloudflare Workers static assets, see wrangler.jsonc).
# Used by Cloudflare Workers Builds (build command) and by the Deploy website CI check.
set -euo pipefail
cd "$(dirname "$0")/.."
# Workers Logs and Traces must stay enabled; a deploy that would turn them off fails here instead.
python3 - <<'PY'
import json, pathlib, re, sys
cfg = re.sub(r"^\s*//.*$", "", pathlib.Path("wrangler.jsonc").read_text(), flags=re.M)
o = json.loads(cfg).get("observability", {})
if not (o.get("enabled") is True and o.get("logs", {}).get("enabled") is True and o.get("traces", {}).get("enabled") is True):
    sys.exit("wrangler.jsonc: observability.enabled, observability.logs.enabled and observability.traces.enabled must all be true")
PY
rm -rf _site
mkdir _site
cp -R website/. _site/
cp registry/registry.json registry/registry.json.sig _site/
# Versions, modules and FAQ answers as plain HTML (crawlers don't run JavaScript), plus sitemap.xml.
python3 website/render.py registry/registry.json _site
rm _site/render.py _site/og-image.svg
