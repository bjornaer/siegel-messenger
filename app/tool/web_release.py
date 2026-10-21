"""M8 part 5: turns `flutter build web` output into a release we can stand behind.

- fonts Flutter would fetch from Google are mirrored here (served from our origin only);
- no service worker (a cached copy could outlive the code we publish);
- Subresource Integrity on the page's scripts;
- .well-known/siegel-web-manifest.txt: the SHA-256 of every file (`sha256sum -c` format), which
  CI attests.

Run as: python3 -I tool/web_release.py build/web
"""
import base64
import hashlib
import os
import re
import sys
import urllib.request

site = sys.argv[1]
js = open(os.path.join(site, "main.dart.js"), encoding="utf-8").read()
fonts = sorted(set(re.findall(r"[a-z0-9]+/v[0-9]+/[A-Za-z0-9_-]+\.(?:ttf|woff2|otf)", js)))
assert "https://fonts.gstatic.com/s/" in js or fonts, "font list moved: check Flutter's fallback"
for f in fonts:
    out = os.path.join(site, "fonts", f)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with urllib.request.urlopen("https://fonts.gstatic.com/s/" + f, timeout=60) as r:
        open(out, "wb").write(r.read())
print(f"mirrored {len(fonts)} fonts")

sw = os.path.join(site, "flutter_service_worker.js")
if os.path.exists(sw):
    os.remove(sw)

index = os.path.join(site, "index.html")
page = open(index, encoding="utf-8").read()
for src in ["pkg/rust_lib_siegel.js", "siegel_core.js", "flutter_bootstrap.js"]:
    digest = base64.b64encode(hashlib.sha384(open(os.path.join(site, src), "rb").read()).digest()).decode()
    tag = f'<script src="{src}"'
    assert tag in page, src
    page = page.replace(tag, f'{tag} integrity="sha384-{digest}"', 1)
open(index, "w", encoding="utf-8").write(page)

lines = []
for d, _, names in os.walk(site):
    for n in names:
        p = os.path.relpath(os.path.join(d, n), site).replace(os.sep, "/")
        if p.startswith(".well-known/"):
            continue
        lines.append(f"{hashlib.sha256(open(os.path.join(d, n), 'rb').read()).hexdigest()}  {p}")
os.makedirs(os.path.join(site, ".well-known"), exist_ok=True)
manifest = os.path.join(site, ".well-known", "siegel-web-manifest.txt")
open(manifest, "w").write("\n".join(sorted(lines, key=lambda l: l[66:])) + "\n")
print(f"manifest: {len(lines)} files")
