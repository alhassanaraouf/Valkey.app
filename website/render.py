#!/usr/bin/env python3
"""Fills the site's registry-driven content into plain HTML so search engines and AI crawlers see it
without running JavaScript, and writes sitemap.xml. Run by the deploy workflow on the assembled site:

    python3 website/render.py registry/registry.json <site-dir>
"""
import datetime
import html
import json
import sys

registry_path, site = sys.argv[1], sys.argv[2]
registry = json.load(open(registry_path))
versions = registry["versions"]
modules = registry.get("modules", [])


def mb(size):
    return f"{size / 1e6:.1f} MB"


def key(version):
    return [int(part) for part in version.split(".")]


def row(*cells):
    return "<tr>" + "".join(f"<td>{html.escape(str(c))}</td>" for c in cells) + "</tr>"


def spoken_list(items):
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1]


version_rows = "".join(row(f"Valkey {v['version']}", v["published"], mb(v["size"])) for v in versions)
module_rows = "".join(row(f"{m['title']} {m['version']}", "Valkey " + ", ".join(m["valkey"]), mb(m["size"]))
                      for m in modules)

newest = sorted((v["version"] for v in versions), key=key)
versions_answer = (f"Valkey.app installs Valkey {spoken_list(newest)}, the latest release of each Valkey line, "
                   "as universal builds for Apple Silicon and Intel. You can run different versions side by side, "
                   "and new Valkey releases are added to its registry without an app update.") if newest else \
                  "Valkey versions are installed from a signed registry; new releases arrive without an app update."
titles = sorted({m["title"] for m in modules})
modules_answer = (f"Yes. You can add official Valkey modules to any server: {spoken_list(titles)}. Each module "
                  "build is tested against the Valkey versions it's offered for, and Valkey.app only shows "
                  "modules that work with your server's version.") if titles else \
                 "Module support is built in; official Valkey modules are added to the registry as they're published."

page_path = f"{site}/index.html"
page = open(page_path).read()
for marker, value in [("<!--VERSIONS-->", version_rows or row("No versions published yet.", "", "")),
                      ("<!--MODULES-->", module_rows or row("No modules published yet.", "", "")),
                      ("{{VERSIONS_ANSWER}}", versions_answer), ("{{MODULES_ANSWER}}", modules_answer)]:
    assert marker in page, f"{marker} missing from index.html"
    page = page.replace(marker, value)
open(page_path, "w").write(page)

today = datetime.date.today().isoformat()
open(f"{site}/sitemap.xml", "w").write(f"""<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://valkey.app/</loc><lastmod>{today}</lastmod></url>
  <url><loc>https://valkey.app/install-valkey-on-mac/</loc><lastmod>{today}</lastmod></url>
</urlset>
""")
print(f"rendered {len(versions)} versions, {len(modules)} modules")
