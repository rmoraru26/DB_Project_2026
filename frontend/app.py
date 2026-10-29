import os
import calendar
import pymysql
from datetime import date, datetime, timedelta
from functools import wraps
from dotenv import load_dotenv
from flask import Flask, redirect, render_template, request, session, url_for
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)

app.secret_key = os.getenv("SECRET_KEY")

# ==========================================
# DATABASE ACCESS & LOGIN REQUIREMENT 
# ==========================================

def get_db_connection():
    try:
        return pymysql.connect (
            user="root",
            password=os.getenv("DB_PASSWORD"),
            host="localhost",
            port=3306,
            database="university_resources"
        )
    except pymysql.Error as e:
        print(f"Database Connection Error: {e}")
        return None

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if session.get("user_id") is None:
            return redirect("/login")

        return f(*args, **kwargs)

    return decorated_function

# ==========================================
# HOMEPAGE & AUTHENTICATION
# ==========================================

# Homepage
@app.route("/")
def index():
    return render_template("index.html")


# Profile Page
@app.route("/profile", methods=["GET", "POST"])
@login_required
def profile():

    user_id = session.get("user_id")
    db = get_db_connection()

    if db:
        cursor = db.cursor()

        # Get User Name
        try:
            sql_query = "SELECT full_name FROM users WHERE user_id = %s"
            cursor.execute(sql_query, (user_id,))
            user = cursor.fetchone()

        except pymysql.Error as e:
            print(f"Error Fetching User Profile: {e}")
            return None

        finally:
            db.close()

    return render_template("profile.html", user_name=user[0])


# Login Page
@app.route("/login", methods=["GET", "POST"])
def login():
    session.clear()
    
    if request.method == "POST":

        # Obtain User Info
        user_email = request.form.get("email")
        user_password = request.form.get("password")

        db = get_db_connection()

        if db:
            cursor = db.cursor()

            # Check Database
            try:
                sql_query = "SELECT user_id, password_hash FROM users WHERE email = %s"
                cursor.execute(sql_query, (user_email,))

                user = cursor.fetchone()

            except pymysql.Error as e:
                print(f"Error during Login: {e}")
                return None

            finally:
                db.close()

            # Verify Valid Login Information
            if user and check_password_hash(user[1], user_password):
                session["user_id"] = user[0]
                return redirect("/")
            else:
                return render_template("login.html", error="Invalid email or password")
        
    return render_template("login.html")


# Logout
@app.route("/logout")
def logout():
    session.clear()
    return redirect("/")


# Register Page
@app.route("/register", methods=["GET", "POST"])
def register():
    if request.method == "POST":

        # Obtain User Info
        user_name = request.form.get("full_name")
        user_email = request.form.get("email")
        user_password = request.form.get("password")
        user_confirm_password = request.form.get("confirm_password")

        if (user_password != user_confirm_password):
            return render_template("register.html", error="Passwords do not match")
        
        hashed_password = generate_password_hash(user_password)

        db = get_db_connection()
        if db:
            cursor = db.cursor()

            # Insert to Database
            try:
                sql_query = "INSERT INTO users (full_name, email, password_hash) VALUES (%s, %s, %s)"
                cursor.execute(sql_query, (user_name, user_email, hashed_password))
                db.commit()

            except pymysql.Error as e:
                print(f"Error Saving User: {e}")
                return render_template("register.html", error="Missing name or email already exists")

            finally:
                db.close()

            return redirect("/login")
            
    return render_template("register.html")


# ==========================================
# BOOKING RULES & HELPERS
# ==========================================

# Rules
ITEM_MAX_DAYS = 14        # items: up to 2 weeks ahead
ROOM_MAX_MONTHS = 3       # rooms: up to 3 months ahead
OPEN_HOUR = 9             # bookable from 09:00 (quiet hours: 22:00 - 09:00)
CLOSE_HOUR = 22           # bookable until 22:00

# Hourly slots, e.g. "09:00 - 10:00"
SLOT_LABELS = [f"{h:02d}:00 - {h + 1:02d}:00" for h in range(OPEN_HOUR, CLOSE_HOUR)]

# Temporary in-memory storage until the database is connected
# Each booking: {kind, name, version, start, end, user_id}
BOOKINGS = []


# Add months to a date (keeps the day valid, e.g. Jan 31 + 1 month = Feb 28)
def add_months(d, months):
    month = d.month - 1 + months
    year = d.year + month // 12
    month = month % 12 + 1
    day = min(d.day, calendar.monthrange(year, month)[1])
    return d.replace(year=year, month=month, day=day)


# Last date a user is allowed to book ("item" or "room")
def last_bookable_date(kind):
    today = date.today()
    if kind == "item":
        return today + timedelta(days=ITEM_MAX_DAYS)
    return add_months(today, ROOM_MAX_MONTHS)


# Checks all booking rules. Returns (error_message, start, end); error_message is None if valid
def validate_booking(kind, name, version, date_str, slot_label):
    try:
        day = datetime.strptime(date_str, "%Y-%m-%d").date()
        start_str, end_str = slot_label.split(" - ")
        start = datetime.combine(day, datetime.strptime(start_str, "%H:%M").time())
        end = datetime.combine(day, datetime.strptime(end_str, "%H:%M").time())
    except (ValueError, TypeError, AttributeError):
        return "Please choose a valid date and time slot.", None, None

    # Can't book before the current date/time
    if start < datetime.now():
        return "You cannot book in the past.", None, None

    # Can't book too far in advance
    if day > last_bookable_date(kind):
        if kind == "item":
            return f"Items can only be booked up to {ITEM_MAX_DAYS} days in advance.", None, None
        return f"Rooms can only be booked up to {ROOM_MAX_MONTHS} months in advance.", None, None

    # Can't book during quiet hours (checked here in case the form is tampered with)
    if start.hour < OPEN_HOUR or end > datetime.combine(day, datetime.min.time()).replace(hour=CLOSE_HOUR):
        return "You cannot book during quiet hours.", None, None

    # Overlap check (items: per version, rooms: per room)
    for b in BOOKINGS:
        if b["kind"] == kind and b["name"] == name and b["version"] == version:
            if b["start"] < end and start < b["end"]:
                return "That time slot is already booked.", None, None

    return None, start, end


# Bookings as calendar events (green = yours, grey = other users)
def get_events(kind, name):
    events = []
    for b in BOOKINGS:
        if b["kind"] == kind and b["name"] == name:
            mine = b["user_id"] == session.get("user_id")
            title = "Your booking" if mine else "Booked"
            if b["version"]:
                title += f" ({b['version']})"
            events.append({
                "title": title,
                "start": b["start"].isoformat(),
                "end": b["end"].isoformat(),
                "color": "#198754" if mine else "#6c757d",
            })
    return events


# Everything the booking pages and the calendar need
def booking_context(kind, name, error=None):
    return {
        "slots": SLOT_LABELS,
        "min_date": date.today().isoformat(),
        "max_date": last_bookable_date(kind).isoformat(),
        "slot_min": f"{OPEN_HOUR:02d}:00:00",
        "slot_max": f"{CLOSE_HOUR:02d}:00:00",
        "events": get_events(kind, name),
        "error": error,
    }


# ==========================================
# ITEMS TO LOAN
# ==========================================

# Items Homepage
@app.route("/itemsHome", methods=["GET", "POST"])
@login_required
def items_home():
    inventory_data = {
        "Cleaning Items": ["Vacuum", "Mop", "Iron", "Broom"],
    
        "Board Games": ["Chess", "Monopoly", "Settlers of Catan", "Scrabble", "Battleship"],
    
        "Sports Items": ["Basketball", "Football", "Frisbee", "Tennis Racket"],
    
        "Electronics": ["Speaker", "PS5 Controller", "Headphones", "Nintendo Switch", "Gameboy"]
    }

    return render_template("items/itemsHome.html", inventory=inventory_data)


# Booking Item
@app.route("/items/<item_name>")
@login_required
def item_booking(item_name):
    # Future Plans:
    # Ask the database for all versions of this item

    return render_template("items/itemBooking.html", item_name=item_name,
                           **booking_context("item", item_name))


# Verify Booking Item
@app.route("/items/<item_name>/verifyBooking", methods=["POST"])
@login_required
def verify_item_booking(item_name):
    error, _, _ = validate_booking("item", item_name, request.form.get("version"),
                                   request.form.get("date"), request.form.get("time"))
    if error:
        return render_template("items/itemBooking.html", item_name=item_name,
                               **booking_context("item", item_name, error))

    return render_template("items/verifyItemBooking.html", item_name=item_name)


# Confirm Booking Item (saves booking, goes back to Items Homepage)
@app.route("/items/<item_name>/confirmBooking", methods=["POST"])
@login_required
def confirm_item_booking(item_name):
    version = request.form.get("version")

    # Check the rules again before saving
    error, start, end = validate_booking("item", item_name, version,
                                         request.form.get("date"), request.form.get("time"))
    if error:
        return render_template("items/itemBooking.html", item_name=item_name,
                               **booking_context("item", item_name, error))

    # Save booking (temporary list until the database is connected)
    BOOKINGS.append({"kind": "item", "name": item_name, "version": version,
                     "start": start, "end": end, "user_id": session["user_id"]})

    return redirect(url_for("items_home"))


# ==========================================
# ROOMS TO BOOK
# ==========================================

# Rooms Homepage
@app.route("/roomsHome", methods=["GET", "POST"])
@login_required
def rooms_home():
    rooms_data = ["Study Room", "Meeting Room", "Studio Room", "Practice Room", "Cinema Room"]

    return render_template("rooms/roomsHome.html", rooms=rooms_data)


# Booking Room
@app.route("/rooms/<room_name>")
@login_required
def room_booking(room_name):
    # Future Plans:
    # Ask the database for all versions of this room

    return render_template("rooms/roomBooking.html", room_name=room_name,
                           **booking_context("room", room_name))


# Verify Booking Room
@app.route("/rooms/<room_name>/verifyBooking", methods=["POST"])
@login_required
def verify_room_booking(room_name):
    error, _, _ = validate_booking("room", room_name, None,
                                   request.form.get("date"), request.form.get("time"))
    if error:
        return render_template("rooms/roomBooking.html", room_name=room_name,
                               **booking_context("room", room_name, error))

    return render_template("rooms/verifyRoomBooking.html", room_name=room_name)


# Confirm Booking Room (saves booking, goes back to Rooms Homepage)
@app.route("/rooms/<room_name>/confirmBooking", methods=["POST"])
@login_required
def confirm_room_booking(room_name):

    # Check the rules again before saving
    error, start, end = validate_booking("room", room_name, None,
                                         request.form.get("date"), request.form.get("time"))
    if error:
        return render_template("rooms/roomBooking.html", room_name=room_name,
                               **booking_context("room", room_name, error))

    # Save booking (temporary list until the database is connected)
    BOOKINGS.append({"kind": "room", "name": room_name, "version": None,
                     "start": start, "end": end, "user_id": session["user_id"]})

    return redirect(url_for("rooms_home"))


if __name__ == "__main__":
    app.run(debug=True)