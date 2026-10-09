#!/usr/bin/env bash
# Download third-party front-end assets into aperisolve/static/vendor/ so the
# site never calls a public CDN (privacy, no external SPOF, cacheable by nginx).
#
# To upgrade a library: change its version below, run this script, update the
# matching path in the templates (grep -rn "static/vendor" aperisolve/templates),
# commit. Versions are part of the path, so browser/nginx caches never serve a
# stale file to a newer template and a rollback to an older image keeps working.
set -euo pipefail

BOOTSTRAP=5.3.8
FONTAWESOME=7.0.1
JSPDF=2.5.2
FIRACODE=5.2.7   # npm: @fontsource-variable/fira-code (OFL-1.1)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/aperisolve/static/vendor"
JSD=https://cdn.jsdelivr.net/npm
CDNJS=https://cdnjs.cloudflare.com/ajax/libs

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

# Bootstrap
d="$ROOT/bootstrap/$BOOTSTRAP"; mkdir -p "$d"
fetch "$JSD/bootstrap@$BOOTSTRAP/dist/css/bootstrap.min.css" "$d/bootstrap.min.css"
# Drop the sourceMappingURL comment: the .map is not shipped, DevTools would 404.
sed -i '/sourceMappingURL/d' "$d/bootstrap.min.css"

# Font Awesome (css references ../webfonts/*.woff2, keep that layout)
d="$ROOT/fontawesome/$FONTAWESOME"; mkdir -p "$d/css" "$d/webfonts"
fetch "$CDNJS/font-awesome/$FONTAWESOME/css/all.min.css" "$d/css/all.min.css"
grep -o 'webfonts/[A-Za-z0-9_.-]*\.woff2' "$d/css/all.min.css" | sort -u | while read -r f; do
  fetch "$CDNJS/font-awesome/$FONTAWESOME/$f" "$d/$f"
done

# jsPDF (only used by /map)
d="$ROOT/jspdf/$JSPDF"; mkdir -p "$d"
fetch "$JSD/jspdf@$JSPDF/dist/jspdf.umd.min.js" "$d/jspdf.umd.min.js"

# Fira Code variable font, split in unicode-range subsets (the browser loads
# only the subsets a page uses, e.g. latin + cyrillic for the ru translation).
d="$ROOT/fira-code/$FIRACODE"; mkdir -p "$d/files"
fetch "$JSD/@fontsource-variable/fira-code@$FIRACODE/wght.css" "$d/fira-code.css"
grep -o 'files/[a-z0-9-]*\.woff2' "$d/fira-code.css" | sort -u | while read -r f; do
  fetch "$JSD/@fontsource-variable/fira-code@$FIRACODE/$f" "$d/$f"
done
# Expose it under the name aperisolve.css already uses.
sed -i "s/'Fira Code Variable'/'Fira Code'/g; s#url(\./files/#url(files/#" "$d/fira-code.css"

echo "Vendored assets written to $ROOT"
du -sh "$ROOT"/*
