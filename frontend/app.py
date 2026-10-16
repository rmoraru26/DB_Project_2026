import pymysql
from flask import Flask, render_template, request, session
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)


# ==========================================
# HOMEPAGE & AUTHENTICATION ROUTES
# ==========================================

# Homepage
@app.route("/")
def index():
    return render_template("index.html")


# Login Page
@app.route("/login", methods=["GET", "POST"])
def login():
    return render_template("login.html")


# Register Page
@app.route("/register", methods=["GET", "POST"])
def register():
    return render_template("register.html")


# ==========================================
# ITEMS & EQUIPMENT ROUTES
# ==========================================

# Items Homepage
@app.route("/itemsHome", methods=["GET", "POST"])
def items_home():
    inventory_data = {
        "Cleaning Items": ["Vacuum", "Mop", "Iron", "Broom"],
    
        "Board Games": ["Chess", "Monopoly", "Settlers of Catan", "Scrabble", "Battleship"],
    
        "Sports Equipment": ["Basketball", "Football", "Frisbee", "Tennis Racket", "Badminton Racket"],
    
        "Electronics": ["Speaker", "PS5 Controller", "Headphones", "Nintendo Switch", "Gameboy"]
    }

    return render_template("items/itemsHome.html", inventory=inventory_data)

# Booking Item
@app.route("/items/<item_name>")
def item_booking(item_name):
    # Future Plans:
    # Ask the database for all versions of this item
    # Ask the database for all available times for this item

    return render_template("items/itemBooking.html", item_name=item_name)


# Verify Booking Item
@app.route("/items/<item_name>/verifyBooking", methods=["POST"])
def verify_item_booking(item_name):
    # Future Plans:
    # Verify that the user has selected a valid time and version
    # If available, save to database
    # If unavailable, send error message

    return render_template("items/verifyItemBooking.html", item_name=item_name)


# ==========================================
# ROOMS ROUTES
# ==========================================

# Rooms Homepage
@app.route("/roomsHome", methods=["GET", "POST"])
def rooms_home():
    rooms_data = ["Study Room", "Meeting Room", "Studio Room", "Practice Room", "Cinema Room"]

    return render_template("rooms/roomsHome.html", rooms=rooms_data)