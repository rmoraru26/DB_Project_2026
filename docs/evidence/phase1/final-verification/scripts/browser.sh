#!/usr/bin/env bash
# Browser tests and the three-width page check against the final Linux stack
# (frt-final-28f2fc09), from the Playwright image on that stack's Compose network.
# Runs on the Windows host (Git Bash); the credentials are read from the Linux
# driver container's private files into environment variables of the browser
# container only, and never printed.
set -u
OUT=$1; CAPTURE=$2
H=frt-final-linuxhost-28f2fc09; NET=frt-final-28f2fc09_default; B=frt-final-browser-28f2fc09
IMG=mcr.microsoft.com/playwright/python:v1.55.0-noble
export MSYS_NO_PATHCONV=1
mkdir -p "$OUT"
docker rm -f "$B" >/dev/null 2>&1
docker run -d --name "$B" --network "$NET" --entrypoint sleep "$IMG" infinity >/dev/null || exit 2
trap 'docker rm -f "$B" >/dev/null 2>&1' EXIT
docker exec "$H" tar -C /work/final -cf - frontend | docker exec -i "$B" sh -c 'mkdir -p /src && tar -C /src -xf -'
docker cp "$(cygpath -w "$CAPTURE")" "$B:/src/capture_pages.py" >/dev/null
{ echo "# $(date -u +%FT%TZ) pip install -r frontend/requirements.txt -r frontend/requirements-browser.txt (pytest==9.1.1, playwright==1.55.0)"
  docker exec "$B" python3 -m pip install --break-system-packages -q -r /src/frontend/requirements.txt -r /src/frontend/requirements-browser.txt 2>&1 | tail -n 3; echo "# exit status: $?"; } > "$OUT/24a-browser-setup.txt" 2>&1
{ echo "# $(date -u +%FT%TZ) Playwright $(docker exec "$B" python3 -c 'import importlib.metadata as m; print(m.version("playwright"))'), pytest $(docker exec "$B" python3 -c 'import importlib.metadata as m; print(m.version("pytest"))'), Chromium headless, base URL http://web:5000 (the web container on the Compose network $NET)"
  docker exec -e RUN_BROWSER_TESTS=1 -e LAB_BASE_URL=http://web:5000 -e SCREENSHOT_DIR=/out/screenshots -w /src/frontend "$B" python3 -m pytest -v tests/browser 2>&1
  echo "# exit status: $?"; } > "$OUT/24-browser-tests.txt" 2>&1
demo=$(docker exec "$H" cat /work/final/.demo-credentials); admin=$(docker exec "$H" cat /work/final/.admin-credentials)
DEMO_EMAIL=$(printf '%s\n' "$demo" | sed -n 1p) DEMO_PASSWORD=$(printf '%s\n' "$demo" | sed -n 2p) \
ADMIN_EMAIL=$(printf '%s\n' "$admin" | sed -n 1p) ADMIN_PASSWORD=$(printf '%s\n' "$admin" | sed -n 2p) \
  bash -c '{ echo "# $(date -u +%FT%TZ) every page at 1280, 768 and 390 px (capture_pages.py from Phase 1), base URL http://web:5000"; docker exec -e DEMO_EMAIL -e DEMO_PASSWORD -e ADMIN_EMAIL -e ADMIN_PASSWORD -e LAB_BASE_URL=http://web:5000 -e OUT_DIR=/out/pages '"$B"' python3 /src/capture_pages.py 2>&1; echo "# exit status: $?"; }' > "$OUT/25-pages-three-widths.txt" 2>&1
unset demo admin
mkdir -p "$OUT/browser-files"
docker cp "$B:/out/." "$(cygpath -w "$OUT/browser-files")" >/dev/null 2>&1
echo "browser tests: $(grep -E '[0-9]+ (passed|failed)' "$OUT/24-browser-tests.txt" | tail -n 1) / $(tail -n 1 "$OUT/24-browser-tests.txt")"
echo "pages: $(grep -c 'HTTP' "$OUT/25-pages-three-widths.txt") page-views; non-zero overflow: $(grep 'HTTP' "$OUT/25-pages-three-widths.txt" | grep -vc 'overflow   0px'); console errors>0: $(grep 'HTTP' "$OUT/25-pages-three-widths.txt" | grep -vc 'console errors 0') / $(tail -n 1 "$OUT/25-pages-three-widths.txt")"
