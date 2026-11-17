"""Visual QA capture: every page of the web app at three widths (review aid).

Runs in the Playwright container on the stack's network.  Credentials come
from the environment and are never printed.  Also reports horizontal overflow
and console errors per page and viewport.
"""
import os
import re
import sys
from datetime import date, timedelta

from playwright.sync_api import sync_playwright

BASE = os.environ.get("LAB_BASE_URL", "http://web:5000")
OUT = os.environ.get("OUT_DIR", "/out/pages")
VIEWPORTS = {"desktop": (1280, 900), "tablet": (768, 1024), "phone": (390, 844)}
tomorrow = (date.today() + timedelta(days=1)).isoformat()

PUBLIC = [("home", "/"), ("login", "/login"), ("register", "/register"), ("lab", "/lab")]
STUDENT = [("home-signed-in", "/"), ("items-home", "/itemsHome"), ("item-booking", "/items/Chess"),
           ("rooms-home", "/roomsHome"), ("room-booking", "/rooms/Study%20Room"),
           ("account-profile", "/accountProfile"), ("account-bookings", "/accountBookings"),
           ("account-settings", "/accountSettings"), ("lab-signed-in", "/lab"),
           ("admin-audit-as-student-403", "/admin/audit"), ("not-found-404", "/no-such-page")]
ADMIN = [("admin-audit", "/admin/audit")]


def login(page, email, password):
    page.goto(BASE + "/login")
    page.fill('input[name="email"]', email)
    page.fill('input[name="password"]', password)
    page.click('button[type="submit"], input[type="submit"]')
    page.wait_for_load_state("networkidle")
    return "/login" not in page.url


def capture(page, name, path, viewport, report):
    errors = []
    handler = lambda m: errors.append(m.text) if m.type == "error" else None
    page.on("console", handler)
    response = page.goto(BASE + path)
    page.wait_for_load_state("networkidle")
    overflow = page.evaluate("document.documentElement.scrollWidth - document.documentElement.clientWidth")
    page.screenshot(path=os.path.join(OUT, f"{viewport}-{name}.png"), full_page=True)
    page.remove_listener("console", handler)
    status = response.status if response else "?"
    expected = re.compile(r"status of (401|403|404)")
    errors = [e for e in errors if not expected.search(e)]
    report.append(f"{viewport:8} {name:28} HTTP {status}  horizontal overflow {overflow:>3}px  console errors {len(errors)}")


def main():
    os.makedirs(OUT, exist_ok=True)
    report = []
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        for viewport, (width, height) in VIEWPORTS.items():
            context = browser.new_context(viewport={"width": width, "height": height})
            page = context.new_page()
            for name, path in PUBLIC:
                capture(page, name, path, viewport, report)
            if login(page, os.environ["DEMO_EMAIL"], os.environ["DEMO_PASSWORD"]):
                for name, path in STUDENT:
                    capture(page, name, path, viewport, report)
            else:
                report.append(f"{viewport}: demo login failed")
            context.close()
            if os.environ.get("ADMIN_PASSWORD"):
                context = browser.new_context(viewport={"width": width, "height": height})
                page = context.new_page()
                if login(page, os.environ["ADMIN_EMAIL"], os.environ["ADMIN_PASSWORD"]):
                    for name, path in ADMIN:
                        capture(page, name, path, viewport, report)
                else:
                    report.append(f"{viewport}: administrator login failed")
                context.close()
        browser.close()
    print("\n".join(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
