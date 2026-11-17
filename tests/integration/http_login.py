"""Logs in to the running web app over HTTP and reports what the session may do.

Runs INSIDE the web container, where the app listens on 127.0.0.1:5000 on
every platform (no published port, curl or host Python needed):

    LOGIN_EMAIL=... LOGIN_PASSWORD=... \
        docker compose exec -T -e LOGIN_EMAIL -e LOGIN_PASSWORD web python - < tests/integration/http_login.py

The credentials come from the environment and are never printed.  Output is
one line of key=value pairs, for example

    login=302 session=yes admin_audit=403 events_scope=mine items_home=200

login         status of POST /login (302 = accepted, 401 = rejected, 429 = throttled)
session       yes if the login produced a signed-in session (GET /accountProfile is 200)
admin_audit   status of GET /admin/audit (200 only for an administrator, 403 for a student)
events_scope  the scope the Audit Lab grants when "all" is requested ("mine" for a student)
items_home    status of GET /itemsHome (200 when signed in)

Only the Python standard library is used.  Exit status 0 when the page flow
itself worked (whatever the login result), 2 on a transport or parsing error.
"""
import http.cookiejar
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("LOGIN_BASE_URL", "http://127.0.0.1:5000")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def main():
    email = os.environ.get("LOGIN_EMAIL")
    password = os.environ.get("LOGIN_PASSWORD")
    if not email or not password:
        print("LOGIN_EMAIL and LOGIN_PASSWORD must be set", file=sys.stderr)
        return 2
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect)

    def fetch(path, data=None):
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        try:
            with opener.open(urllib.request.Request(BASE + path, data=body), timeout=15) as response:
                return response.status, response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode("utf-8", "replace")

    status, page = fetch("/login")
    token = re.search(r'name="csrf_token"\s+value="([^"]+)"', page)
    if status != 200 or not token:
        print("could not read the login form (status %s)" % status, file=sys.stderr)
        return 2
    login_status, _ = fetch("/login", {"csrf_token": token.group(1), "email": email, "password": password})
    profile_status, _ = fetch("/accountProfile")
    admin_status, _ = fetch("/admin/audit")
    events_status, events_body = fetch("/lab/api/events?scope=all")
    scope = "-"
    if events_status == 200:
        try:
            scope = str(json.loads(events_body).get("scope", "-"))
        except ValueError:
            scope = "unparsable"
    items_status, _ = fetch("/itemsHome")
    print("login=%s session=%s admin_audit=%s events_scope=%s items_home=%s" % (
        login_status, "yes" if profile_status == 200 else "no", admin_status, scope, items_status))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
