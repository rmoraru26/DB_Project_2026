import os
import pymysql
from functools import wraps
from dotenv import load_dotenv
from flask import Flask, redirect, render_template, request, session
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
    # Ask the database for all available times for this item

    return render_template("items/itemBooking.html", item_name=item_name)


# Verify Booking Item
@app.route("/items/<item_name>/verifyBooking", methods=["POST"])
@login_required
def verify_item_booking(item_name):
    # Future Plans:
    # Verify that the user has selected a valid time and version
    # If available, save to database
    # If unavailable, send error message

    return render_template("items/verifyItemBooking.html", item_name=item_name)


# ==========================================
# ROOMS TO BOOK
# ==========================================

# Rooms Homepage
@app.route("/roomsHome", methods=["GET", "POST"])
@login_required
def rooms_home():
    rooms_data = ["Study Room", "Meeting Room", "Studio Room", "Practice Room", "Cinema Room"]

    return render_template("rooms/roomsHome.html", rooms=rooms_data)