"""The Audit Lab in a real browser, against a running app and database.

    make up && make test-browser

The first `make test-browser` bootstraps an isolated `.venv-browser` environment
and installs the pinned Playwright package plus Chromium. To set it up separately,
run `make browser-setup` once. No host Python packages are installed globally.

Environment:
    RUN_BROWSER_TESTS=1     required; otherwise every test is skipped
    LAB_BASE_URL            default http://127.0.0.1:5080
    PLAYWRIGHT_CHANNEL      optional installed browser, e.g. msedge or chrome
    SCREENSHOT_DIR          optional; saves the screenshots used in the README

Nothing is mocked: the tests register a new user through the form, log in,
and read records that the campus_audit plugin wrote inside the server.
"""
import os
import random
import re
import secrets

import pytest

sync_api = pytest.importorskip("playwright.sync_api")

pytestmark = pytest.mark.skipif(os.getenv("RUN_BROWSER_TESTS") != "1",
                                reason="set RUN_BROWSER_TESTS=1 with the app running (make up)")

BASE = os.getenv("LAB_BASE_URL", "http://127.0.0.1:5080").rstrip("/")
SHOTS = os.getenv("SCREENSHOT_DIR")
DIGEST = "INSERT INTO audit_lab_notes (owner_user_id, label, quantity) VALUES (?, ?, ?)"


@pytest.fixture(scope="module")
def browser():
    with sync_api.sync_playwright() as p:
        channel = os.getenv("PLAYWRIGHT_CHANNEL") or None
        b = p.chromium.launch(channel=channel, headless=True)
        yield b
        b.close()


@pytest.fixture()
def page(browser):
    context = browser.new_context(viewport={"width": 1280, "height": 900})
    pg = context.new_page()
    errors = []
    # 401 (wrong password) and 429 (throttled) are answers the app gives on purpose.
    expected = re.compile(r"responded with a status of (401|429)")
    pg.on("pageerror", lambda e: errors.append(str(e)))
    pg.on("console", lambda m: errors.append(m.text)
          if m.type == "error" and not expected.search(m.text) else None)
    yield pg
    context.close()
    assert not errors, f"browser errors: {errors}"


def shot(page, name):
    if SHOTS:
        os.makedirs(SHOTS, exist_ok=True)
        page.screenshot(path=os.path.join(SHOTS, name), full_page=True)


@pytest.fixture(scope="module")
def account(browser):
    """A student account registered through the form for this test module.

    No demo password is published: the seed's users cannot log in, so the
    tests create their own account with a random password.
    """
    email = f"lab.browser.{random.randint(0, 10**9)}@example.edu"
    password = "browser-" + secrets.token_urlsafe(12)
    context = browser.new_context()
    pg = context.new_page()
    pg.goto(BASE + "/register")
    pg.fill("#reg-name", "Lab Browser Test")
    pg.fill("#reg-email", email)
    pg.fill("#reg-password", password)
    pg.fill("#reg-confirm", password)
    pg.click("form button[type=submit]")
    pg.wait_for_url(re.compile(r".*/login$"))
    context.close()
    return email, password


ACCOUNT = {}


@pytest.fixture(autouse=True)
def _module_account(account):
    ACCOUNT["email"], ACCOUNT["password"] = account


def log_in(page, email=None, password=None, next_lab=True):
    email = email or ACCOUNT["email"]
    password = password or ACCOUNT["password"]
    page.goto(BASE + ("/login?next=lab" if next_lab else "/login"))
    page.fill("#login-email", email)
    page.fill("#login-password", password)
    page.click("form button[type=submit]")


def progress(page):
    return page.locator("#lab-progress-text").inner_text()


def go(page, step):
    page.click(f"#lab-step-list [data-goto='{step}']")
    sync_api.expect(page.locator(f".lab-step[data-step='{step}']")).to_be_visible()


# ------------------------------------------------------------------ accounts

def test_register_then_log_in_through_the_forms(page):
    email = f"browser.{random.randint(0, 10**9)}@example.edu"
    page.goto(BASE + "/register")
    page.fill("#reg-name", "Browser Test")
    page.fill("#reg-email", email)
    page.fill("#reg-password", "a-long-password")
    page.fill("#reg-confirm", "a-long-password")
    page.click("form button[type=submit]")
    page.wait_for_url(re.compile(r".*/login$"))
    sync_api.expect(page.locator(".alert-info")).to_contain_text("Account created")
    log_in(page, email, "a-long-password", next_lab=False)
    page.wait_for_url(BASE + "/")
    sync_api.expect(page.locator("nav")).to_contain_text("Profile")


def test_wrong_password_is_refused_without_an_error_page(page):
    log_in(page, password="not-the-password", next_lab=False)
    sync_api.expect(page.locator(".alert-danger")).to_contain_text("Invalid email or password")


# ------------------------------------------------------------------ tour mechanics

def test_newcomer_finds_the_tour_from_the_homepage(page):
    page.goto(BASE + "/")
    shot(page, "01-home.png")
    page.click("text=Start Guided Tour")
    page.wait_for_url(re.compile(r".*/lab"))
    sync_api.expect(page.locator("h1.lab-title")).to_have_text("Audit Lab")


def test_logged_out_visitors_get_the_public_steps_and_a_login_prompt(page):
    page.goto(BASE + "/lab?step=3")
    sync_api.expect(page.locator(".lab-step[data-step='3'] .lab-login")).to_be_visible()
    go(page, 2)
    sync_api.expect(page.locator(".lab-diagram")).to_be_visible()


def test_next_back_skip_restart_keyboard_and_persistence(page):
    log_in(page)
    page.wait_for_url(re.compile(r".*/lab$"))
    page.click("[data-tour=start]")
    assert progress(page).startswith("Step 1 of 9")
    sync_api.expect(page.locator(".lab-nav [data-tour=back]")).to_be_disabled()
    page.click(".lab-nav [data-tour=next]")
    assert progress(page).startswith("Step 2 of 9")
    shot(page, "02-architecture.png")
    page.click(".lab-nav [data-tour=back]")
    assert progress(page).startswith("Step 1 of 9")
    page.locator("body").press("ArrowRight")
    assert progress(page).startswith("Step 2 of 9")
    go(page, 8)
    sync_api.expect(page.locator("#lab-step-list [data-goto='8']")).to_have_attribute("aria-current", "step")
    sync_api.expect(page.locator(".lab-progress")).to_have_attribute("aria-valuenow", "8")
    page.click(".lab-nav [data-tour=restart]")
    assert progress(page).startswith("Step 1 of 9")
    page.click("[data-tour=skip]")
    assert progress(page).startswith("Step 7 of 9")
    page.reload()
    assert progress(page).startswith("Step 7 of 9"), "progress is kept across a reload"


# ------------------------------------------------------------------ live records

def test_plugin_state_comes_from_the_server(page):
    log_in(page)
    page.wait_for_url(re.compile(r".*/lab$"))
    go(page, 3)
    sync_api.expect(page.locator(".lab-status")).to_contain_text("campus_audit is loaded and writing")
    sync_api.expect(page.locator("#plugin-state")).to_contain_text("AUDIT")
    shot(page, "03-plugin-state.png")


def test_insert_shows_plugin_records_and_the_trigger_row(page):
    label = f"Browser label {random.randint(0, 10**6)}"
    log_in(page)
    page.wait_for_url(re.compile(r".*/lab$"))
    go(page, 4)
    page.fill("#lab-label", label)
    page.fill("#lab-quantity", "3")
    page.click("[data-action=create]")
    sync_api.expect(page.locator(".lab-outcome--ok")).to_be_visible()
    shot(page, "04-insert-result.png")

    go(page, 5)
    events = page.locator("#plugin-events")
    sync_api.expect(events.locator(".ev--plugin").first).to_be_visible()
    text = events.text_content()
    assert "table_write" in text and "statement" in text and DIGEST in text
    assert label not in text, "the plugin's records must not contain the inserted value"
    events.locator("details.ev-details summary").first.click()
    shot(page, "05-plugin-records.png")

    go(page, 6)
    history = page.locator("#row-history")
    sync_api.expect(history.locator(".ev--trigger")).to_contain_text("INSERT audit_lab_notes")
    sync_api.expect(history).to_contain_text(label)
    shot(page, "06-row-history.png")


def test_check_violation_is_recorded_without_row_history(page):
    log_in(page)
    page.wait_for_url(re.compile(r".*/lab$"))
    go(page, 4)
    page.click("[data-action=violate]")
    sync_api.expect(page.locator(".lab-outcome--error")).to_contain_text("4025")
    go(page, 5)
    sync_api.expect(page.locator("#plugin-events")).to_contain_text("error 4025")
    shot(page, "07-check-violation.png")
    go(page, 6)
    sync_api.expect(page.locator("#row-history")).to_contain_text("No row history")


def test_explorer_filters_by_event_type(page):
    log_in(page)
    page.wait_for_url(re.compile(r".*/lab$"))
    go(page, 4)
    page.click("[data-action=denied]")
    sync_api.expect(page.locator(".lab-outcome--error")).to_contain_text("1142")
    go(page, 7)
    page.select_option("#event-filters select[name=type]", "statement")
    page.click("#event-filters button[type=submit]")
    cards = page.locator("#event-list .ev")
    sync_api.expect(cards.first).to_be_visible()
    for i in range(cards.count()):
        assert cards.nth(i).locator(".ev-type").inner_text() == "statement"
    sync_api.expect(page.locator("#event-list")).to_contain_text("access denied")
    shot(page, "08-explorer.png")
    page.click("#tab-history")
    sync_api.expect(page.locator("#panel-history")).to_be_visible()


def test_finish_summarises_the_tour(page):
    log_in(page)
    page.wait_for_url(re.compile(r".*/lab$"))
    go(page, 9)
    sync_api.expect(page.locator("#lab-summary")).to_contain_text("statements")
    go(page, 8)
    shot(page, "09-limits.png")


def test_phone_width_has_no_horizontal_scroll(browser):
    context = browser.new_context(viewport={"width": 390, "height": 844})
    pg = context.new_page()
    log_in(pg)
    pg.wait_for_url(re.compile(r".*/lab$"))
    pg.click("#lab-step-list [data-goto='4']")
    overflow = pg.evaluate("document.scrollingElement.scrollWidth - window.innerWidth")
    shot(pg, "10-phone.png")
    context.close()
    assert overflow <= 1
