# Website: page inventory and visual QA checklist

This document prepares the visual review of the web application. **No template or stylesheet was
changed for it.** The files `frontend/templates/`, `frontend/static/styles.css`,
`frontend/static/lab.css` and `frontend/static/lab.js` are being reworked on the `website` branch;
the findings below describe the application as it is on this branch (16 November 2026) and are the
list to check again once that work is integrated.

How the review was done: every page was opened in Chromium (Playwright 1.55.0, headless) against
the running Docker stack at three viewport widths, 1280 x 900 (desktop), 768 x 1024 (tablet) and
390 x 844 (phone), signed out, as the generated demo student and as the generated administrator.
For each page and width the HTTP status, the horizontal overflow
(`scrollWidth - clientWidth` of the document) and the number of console errors were recorded, and
a full-page screenshot was taken and read.

## Page inventory

| # | Page | Route | Template | Needs | Automated test today |
|---|---|---|---|---|---|
| 1 | Home | `/` | `index.html` | nothing | app tests (content), browser test (screenshot) |
| 2 | Login | `/login` | `login.html` | nothing | app tests, browser tests (form login) |
| 3 | Register | `/register` | `register.html` | nothing | app tests, browser tests (form registration) |
| 4 | Audit Lab, 9 steps | `/lab` | `lab.html` + `lab.css`, `lab.js` | steps 3-7 need a login | lab tests, 11 browser tests incl. 390 px |
| 5 | Items overview | `/itemsHome` | `items/itemsHome.html` | login | app tests |
| 6 | Item booking with calendar | `/items/<name>` | `items/itemBooking.html`, `calendar.html` | login | app tests (booking rules, overlap) |
| 7 | Item booking confirmation | `/items/<name>/verifyBooking` | `items/verifyItemBooking.html` | login, POST | app tests |
| 8 | Rooms overview | `/roomsHome` | `rooms/roomsHome.html` | login | app tests |
| 9 | Room booking with calendar | `/rooms/<name>` | `rooms/roomBooking.html`, `calendar.html` | login | app tests |
| 10 | Room booking confirmation | `/rooms/<name>/verifyBooking` | `rooms/verifyRoomBooking.html` | login, POST | app tests |
| 11 | Profile | `/accountProfile` | `account/accountProfile.html` | login | app tests |
| 12 | My bookings | `/accountBookings` | `account/accountBookings.html` | login | app tests (cancel) |
| 13 | Account settings | `/accountSettings` | `account/accountSettings.html` | login | app tests (name, password) |
| 14 | Change history | `/admin/audit` | `admin/audit.html` | administrator | app tests; database test with the generated administrator |
| 15 | Database unavailable | any page, HTTP 503 | `errors/database.html` | | app tests |
| 16 | Server error | any page, HTTP 500 | `errors/500.html` | | app tests |
| 17 | Forbidden, not found, bad request, throttled | HTTP 403, 404, 400, 429 | **none** (the framework's default page) | | status codes only |

`frontend/templates/myBookings.html` is not rendered by any route of `frontend/app.py`
(`/accountBookings` uses `account/accountBookings.html`); decide during the integration whether it
is still needed.

## Measured on this branch

| Check | Result |
|---|---|
| Pages 1-6, 8, 9, 11-14 plus the 403 and 404 answers, at three widths (48 page loads) | every page answered with the expected status |
| Horizontal overflow | 0 px on all 48 |
| Console errors (other than the expected 401/403/404 answers) | 0 on all 48 |
| Existing responsive test | one: the Audit Lab at 390 px has no horizontal scroll (`frontend/tests/browser/test_lab_browser.py`) |

Pages 7 and 10 (the confirmation step) and the error pages 15 and 16 were not captured: they need
a form submission or a failing database.

## Findings to resolve with the website work

Ordered by how much they stand out in a demonstration.

1. **403 and 404 have no page.** A student who opens `/admin/audit`, or anybody who mistypes an
   address, gets the framework's unstyled text ("Forbidden … It is either read-protected or not
   readable by the server.") without the navigation bar or a way back. The same holds for 400 (an
   expired CSRF token) and 429 (too many login attempts on the JSON endpoints). Needs templates
   `errors/403.html` and `errors/404.html` in the site layout, and the matching error handlers in
   `frontend/app.py` (a backend change of a few lines that can follow the templates).
2. **Navigation at phone width.** The bar does not collapse: the four links stack vertically and
   "Profile" (or "Login / Register") floats at the right edge beside them, taking about a fifth of
   the first screen. A collapsed menu, or one wrapped row, would fix it.
3. **Home page.** Below the two booking cards the page is empty at desktop width; the cards use
   emoji as icons and have different text styles ("Book an item" / "Book a room."). When signed
   out, "Items" and "Rooms" in the bar are greyed out without saying that they need a login.
4. **Booking calendar.** The week view has an empty grey column between the hour labels and Monday,
   and shows Monday to Saturday only; check whether Sunday is bookable and whether that column is
   intended. The form above the calendar and the calendar itself do not share a card.
5. **Headings.** The page titles differ in weight and case from page to page ("Book: Chess",
   "Book an Item... or Multiple", "Audit Lab", "Start Booking"); pick one scale for h1 and h2.
6. **Buttons.** Three styles are in use for the same role: the solid light-blue primary of the
   booking pages and the lab hero, the outlined secondary, and Bootstrap's default blue in the
   calendar toolbar and the wizard. Align them.
7. **Audit Lab step list at phone width.** The nine numbered steps become a horizontal strip that
   is cut off after step 7; it scrolls, but nothing indicates that. The lab itself reads well at all
   three widths and is the strongest page; keep its card and badge styles as the reference for the
   rest.
8. **Change history (`/admin/audit`).** Wide tables: check the horizontal scrolling inside the
   table containers at tablet and phone width after the redesign.

## Checklist for the review after integration

Run for each page of the inventory, at 1280, 768 and 390 px, signed out, as student and as
administrator:

- [ ] the page uses the shared layout: navigation bar, container width, footer if any
- [ ] no horizontal scrolling of the page; wide tables scroll inside their own container
- [ ] one h1, a consistent heading scale, no text smaller than 12 px
- [ ] primary and secondary buttons look the same on every page; focus is visible with the keyboard
- [ ] form fields have labels; errors appear next to the form in the same style everywhere
- [ ] flashed messages ("Booking confirmed.", "You have been logged out.") are visible and styled
- [ ] the navigation works at 390 px and shows who is signed in
- [ ] every error status (400, 403, 404, 429, 500, 503) has a page in the site layout with a way back
- [ ] images have `alt` text and do not shift the layout while loading
- [ ] colour contrast of text on buttons and badges is at least 4.5 : 1
- [ ] the Audit Lab: all nine steps, each action button, the record cards with "What each field
      means" open, the explorer filters, the limits step; the browser tests still pass
- [ ] no page, script or stylesheet contains a credential (checked by
      `test_no_demo_credentials_in_pages_or_static_assets`)

## Screenshots to regenerate after integration

The ten images in `docs/screenshots/` are written by the browser tests and were regenerated from
the current application on 16 November 2026 (the previous set showed an older design, and its home
page showed a demo password that no longer exists):

```bash
SCREENSHOT_DIR=docs/screenshots make test-browser
```

In addition, capture for the review, at the three widths: home (signed out and signed in), login,
register, items overview, item booking, the booking confirmation, rooms overview, room booking,
profile, my bookings, account settings, the change history as administrator, and the 403 and 404
pages. The README uses `01-home.png`, `03-plugin-state.png`, `05-plugin-records.png`,
`06-row-history.png` and `08-explorer.png` inline and links the other five.
