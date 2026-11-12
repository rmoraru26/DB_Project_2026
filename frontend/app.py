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
# DATABASE & LOGIN REQUIREMENT 
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

@app.before_request
def auto_cleanup_reservations():
    db = get_db_connection()

    if db:
        try:
            cursor = db.cursor()

            sql_query_items = """
                UPDATE loans
                SET status = 'returned', returned_at = CURRENT_TIMESTAMP(6)
                WHERE status = 'active' AND due_at < CURRENT_TIMESTAMP(6)
            """
            cursor.execute(sql_query_items)

            sql_query_rooms = """
                UPDATE bookings
                SET status = 'completed'
                WHERE status = 'confirmed' AND end_time < CURRENT_TIMESTAMP(6)
            """
            cursor.execute(sql_query_rooms)

            db.commit()

        except pymysql.Error as e:
            print(f"Error auto-cleaning reservations: {e}")

        finally:
            db.close()


def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if session.get("user_id") is None:
            return redirect("/login")

        return f(*args, **kwargs)

    return decorated_function


# ==========================================
# HOME & LAB PAGES
# ==========================================

# Homepage
@app.route("/")
def index():
    return render_template("index.html")


@app.route("/lab", methods=["GET", "POST"])
def lab():

    return render_template("lab.html")



# ==========================================
# ACCOUNT PAGES
# ==========================================

# Account Profile Page
@app.route("/accountProfile", methods=["GET", "POST"])
@login_required
def account_profile():

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

    return render_template("account/accountProfile.html", user_name=user[0])


# Account Bookings Page
@app.route("/accountBookings", methods=["GET", "POST"])
@login_required
def account_bookings():
    db = get_db_connection()
    my_bookings = []

    if db:
        try:
            cursor = db.cursor(pymysql.cursors.DictCursor)
            user_id = session.get("user_id")

            # Get Room Bookings
            sql_rooms = """
                SELECT b.booking_id, r.name, r.capacity, b.start_time, b.end_time
                FROM bookings b
                JOIN rooms r ON b.room_id = r.room_id
                WHERE b.user_id = %s AND b.status = 'confirmed'
            """
            cursor.execute(sql_rooms, (user_id,))
            
            for r in cursor.fetchall():
                my_bookings.append({
                    "id": r['booking_id'],
                    "title": f"Room: {r['name']}",
                    "kind": "room",
                    "details": f"Date: {r['start_time'].strftime('%b %d, %Y')}",
                    "details2": f"Time: {r['start_time'].strftime('%H:%M')} - {r['end_time'].strftime('%H:%M')}",
                    "details3": f"Capacity: {r['capacity']} people",
                    "icon": "&#128682;"
                })

            # Get Item Loans
            sql_items = """
                SELECT l.loan_id, i.name, i.asset_tag, l.borrowed_at, l.due_at
                FROM loans l
                JOIN items i ON l.item_id = i.item_id
                WHERE l.user_id = %s AND l.status = 'active'
            """
            cursor.execute(sql_items, (user_id,))

            for i in cursor.fetchall():
                my_bookings.append({
                    "id": i['loan_id'],
                    "title": f"Item: {i['name']}",
                    "kind": "item",
                    "details": f"Date: {i['borrowed_at'].strftime('%b %d, %Y')}",
                    "details2": f"Time: {i['borrowed_at'].strftime('%H:%M')} - {i['due_at'].strftime('%H:%M')}",
                    "details3": f"Version: {i['asset_tag']}",
                    "icon": "&#128230;"
                })

        except pymysql.Error as e:
            print(f"Error getting account bookings: {e}")

        finally:
            db.close()

    return render_template("account/accountBookings.html", bookings=my_bookings)


# Account Settings Page
@app.route("/accountSettings", methods=["GET", "POST"])
@login_required
def account_settings():
    message = error = None
    db = get_db_connection()
    cursor = db.cursor()

    try:
        if request.method == "POST":

            # Change Name
            if request.form.get("action") == "name":
                new_name = request.form.get("full_name", "").strip()
                if new_name:
                    cursor.execute("UPDATE users SET full_name = %s WHERE user_id = %s",
                                   (new_name, session["user_id"]))
                    db.commit()
                    message = "Name updated."
                else:
                    error = "Name cannot be empty."

            # Change Password
            elif request.form.get("action") == "password":
                cursor.execute("SELECT password_hash FROM users WHERE user_id = %s", (session["user_id"],))
                current_hash = cursor.fetchone()[0]
                new_password = request.form.get("new_password", "")

                if not check_password_hash(current_hash, request.form.get("current_password", "")):
                    error = "Current password is incorrect."
                elif new_password != request.form.get("confirm_password"):
                    error = "New passwords do not match."
                elif len(new_password) < 8:
                    error = "New password must be at least 8 characters."
                else:
                    cursor.execute("UPDATE users SET password_hash = %s WHERE user_id = %s",
                                   (generate_password_hash(new_password), session["user_id"]))
                    db.commit()
                    message = "Password updated."

        cursor.execute("SELECT full_name, email FROM users WHERE user_id = %s", (session["user_id"],))
        user = cursor.fetchone()

    finally:
        db.close()

    return render_template("account/accountSettings.html", user=user, message=message, error=error)


# ==========================================
# AUTHENTICATION
# ==========================================

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

# Booking Rules
ITEM_MAX_DAYS = 14        # items: up to 2 weeks ahead
ROOM_MAX_MONTHS = 3       # rooms: up to 3 months ahead
OPEN_HOUR = 9             # bookable from 09:00 (quiet hours: 22:00 - 09:00)
CLOSE_HOUR = 22           # bookable until 22:00

# Hourly slots, e.g. "09:00 - 10:00"
SLOT_LABELS = [f"{h:02d}:00 - {h + 1:02d}:00" for h in range(OPEN_HOUR, CLOSE_HOUR)]


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

    if start < datetime.now():
        return "You cannot book in the past.", None, None

    if day > last_bookable_date(kind):
        if kind == "item":
            return f"Items can only be booked up to {ITEM_MAX_DAYS} days in advance.", None, None
        return f"Rooms can only be booked up to {ROOM_MAX_MONTHS} months in advance.", None, None

    if start.hour < OPEN_HOUR or end > datetime.combine(day, datetime.min.time()).replace(hour=CLOSE_HOUR):
        return "You cannot book during quiet hours.", None, None


    # Check for overlaps in database
    db = get_db_connection()
    if not db:
        return "Database connection error.", None, None
        
    try:
        cursor = db.cursor()
        overlap_count = 0
        
        if kind == "room":
            query = """
                SELECT COUNT(*) FROM bookings b
                JOIN rooms r ON b.room_id = r.room_id
                WHERE r.name = %s AND b.status = 'confirmed'
                AND b.start_time < %s AND b.end_time > %s
            """
            cursor.execute(query, (name, end, start))
            overlap_count = cursor.fetchone()[0]
            
        elif kind == "item":
            if version:
                query = """
                    SELECT COUNT(*) FROM loans l
                    JOIN items i ON l.item_id = i.item_id
                    WHERE i.name = %s AND i.asset_tag = %s AND l.status = 'active'
                    AND l.borrowed_at < %s AND l.due_at > %s
                """
                cursor.execute(query, (name, version, end, start))
            else:
                query = """
                    SELECT COUNT(*) FROM loans l
                    JOIN items i ON l.item_id = i.item_id
                    WHERE i.name = %s AND l.status = 'active'
                    AND l.borrowed_at < %s AND l.due_at > %s
                """
                cursor.execute(query, (name, end, start))
            overlap_count = cursor.fetchone()[0]

        if overlap_count > 0:
            return "That time slot is already booked.", None, None

    except pymysql.Error as e:
        print(f"Error checking overlaps: {e}")
        return "Error checking availability.", None, None

    finally:
        db.close()

    return None, start, end


# Bookings as Calendar Events (green = yours, red = other users, grey = past)
def get_events(kind, name):
    events = []
    db = get_db_connection()

    if not db:
        return events
        
    current_user_id = session.get("user_id")
        
    try:
        cursor = db.cursor(pymysql.cursors.DictCursor) 
        
        if kind == "room":
            query = """
                SELECT b.start_time, b.end_time, b.user_id, b.status, NULL as version
                FROM bookings b
                JOIN rooms r ON b.room_id = r.room_id
                WHERE r.name = %s AND b.status IN ('confirmed', 'completed')
            """
            cursor.execute(query, (name,))
            
        elif kind == "item":
            query = """
                SELECT l.borrowed_at as start_time, l.due_at as end_time, l.user_id, l.status, i.asset_tag as version
                FROM loans l
                JOIN items i ON l.item_id = i.item_id
                WHERE i.name = %s AND l.status IN ('active', 'returned')
            """
            cursor.execute(query, (name,))
            
        rows = cursor.fetchall()
        
        for row in rows:
            mine = row['user_id'] == current_user_id
            is_past = row['status'] in ('completed', 'returned')

            # Determin color and title
            if is_past:
                color = "#8b8b8b" if mine else "#484848"
                title = "Completed" if mine else "Booked (Past)"
            
            else:
                color = "#198733" if mine else "#e73a3a"
                title = "Your Booking" if mine else "Booked"
            
            if row['version']:
                title += f" ({row['version']})"
                
            events.append({
                "title": title,
                "start": row['start_time'].isoformat(),
                "end": row['end_time'].isoformat(),
                "color": color,
            })
            
    except pymysql.Error as e:
        print(f"Error fetching events: {e}")

    finally:
        db.close()
        
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

    db = get_db_connection()

    if db:
        try:
            cursor = db.cursor()

            # Get User ID (asset_tag == item version)
            if version:
                cursor.execute("SELECT item_id FROM items WHERE name = %s AND asset_tag = %s", (item_name, version))
            else:
                cursor.execute("SELECT item_id FROM items WHERE name = %s LIMIT 1", (item_name,))

            item = cursor.fetchone()

            if item:
                item_id = item[0]

                sql_query = """
                    INSERT INTO loans (user_id, item_id, borrowed_at, due_at, status)
                    VALUES (%s, %s, %s, %s, 'active')
                """

                cursor.execute(sql_query, (session["user_id"], item_id, start, end))
                db.commit()
    
        except pymysql.Error as e:
            print(f"Error Saving Item Loan: {e}")

        finally:
            db.close()

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

    db = get_db_connection()

    if db:
        try:
            cursor = db.cursor()

            # Select Room ID
            sql_query = "SELECT room_id FROM rooms where name = %s"
            cursor.execute(sql_query, (room_name,))
            room = cursor.fetchone()

            if room:
                room_id = room[0]

                # Insert into Bookings Table
                sql_query2 = """
                    INSERT INTO bookings (user_id, room_id, start_time, end_time, status)
                    VALUES (%s, %s, %s, %s, 'confirmed')
                """

                cursor.execute(sql_query2, (session["user_id"], room_id, start, end))
                db.commit()

        except pymysql.Error as e:
            print(f"Error Saving Room Booking: {e}")

        finally:
            db.close()

    return redirect(url_for("rooms_home"))


# ==========================================
# CANCEL BOOKINGS
# ==========================================

@app.route("/cancelBooking", methods=["POST"])
@login_required
def cancel_booking():
    booking_id = request.form.get("booking_id")
    kind = request.form.get("kind")
    user_id = session.get("user_id")

    db = get_db_connection()

    if db:
        try:
            cursor = db.cursor()

            if kind == "room":
                sql_query = """
                    UPDATE bookings 
                    SET status = 'cancelled' 
                    WHERE booking_id = %s AND user_id = %s 
                """
                cursor.execute(sql_query, (booking_id, user_id))

            elif kind == "item":
                cursor.execute(
                    """
                    DELETE FROM loans
                    WHERE loan_id = %s AND user_id = %s AND status = 'active'
                      AND borrowed_at > CURRENT_TIMESTAMP(6)
                    """,
                    (booking_id, user_id),
                )

                if cursor.rowcount == 0:
                    cursor.execute(
                        """
                        UPDATE loans
                        SET status = 'returned', returned_at = CURRENT_TIMESTAMP(6)
                        WHERE loan_id = %s AND user_id = %s AND status = 'active'
                          AND borrowed_at <= CURRENT_TIMESTAMP(6)
                        """,
                        (booking_id, user_id),
                    )

            db.commit()

        except pymysql.Error as e:
            print(f"Error cancelling booking: {e}")

        finally:
            db.close()

    return redirect(url_for("account_bookings"))


if __name__ == "__main__":
    app.run(debug=True)