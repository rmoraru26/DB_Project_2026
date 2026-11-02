import pymysql
from dotenv import load_dotenv
from app import get_db_connection

load_dotenv()

# Add Items to Database
def seed_items():
    db = get_db_connection()

    if not db:
        print("Could not connect to database")
        return

    try:
        cursor = db.cursor()

        sql_query = """
            INSERT INTO items (name, category, asset_tag, status) VALUES
            ('Vacuum', 'Cleaning Items', 'Vacuum A', 'available'),
            ('Vacuum', 'Cleaning Items', 'Vacuum B', 'available'),
            ('Vacuum', 'Cleaning Items', 'Vacuum C', 'available'),
            ('Mop', 'Cleaning Items', 'Mop A', 'available'),
            ('Mop', 'Cleaning Items', 'Mop B', 'available'),
            ('Mop', 'Cleaning Items', 'Mop C', 'available'),
            ('Iron', 'Cleaning Items', 'Iron A', 'available'),
            ('Iron', 'Cleaning Items', 'Iron B', 'available'),
            ('Iron', 'Cleaning Items', 'Iron C', 'available'),
            ('Broom', 'Cleaning Items', 'Broom A', 'available'),
            ('Broom', 'Cleaning Items', 'Broom B', 'available'),
            ('Broom', 'Cleaning Items', 'Broom C', 'available'),

            ('Chess', 'Board Games', 'Chess A', 'available'),
            ('Chess', 'Board Games', 'Chess B', 'available'),
            ('Chess', 'Board Games', 'Chess C', 'available'),
            ('Monopoly', 'Board Games', 'Monopoly A', 'available'),
            ('Monopoly', 'Board Games', 'Monopoly B', 'available'),
            ('Monopoly', 'Board Games', 'Monopoly C', 'available'),
            ('Settlers of Catan', 'Board Games', 'Settlers of Catan A', 'available'),
            ('Settlers of Catan', 'Board Games', 'Settlers of Catan B', 'available'),
            ('Settlers of Catan', 'Board Games', 'Settlers of Catan C', 'available'),
            ('Scrabble', 'Board Games', 'Scrabble A', 'available'),
            ('Scrabble', 'Board Games', 'Scrabble B', 'available'),
            ('Scrabble', 'Board Games', 'Scrabble C', 'available'),
            ('Battleship', 'Board Games', 'Battleship A', 'available'),
            ('Battleship', 'Board Games', 'Battleship B', 'available'),
            ('Battleship', 'Board Games', 'Battleship C', 'available'),

            ('Basketball', 'Sports Items', 'Basketball A', 'available'),
            ('Basketball', 'Sports Items', 'Basketball B', 'available'),
            ('Basketball', 'Sports Items', 'Basketball C', 'available'),
            ('Football', 'Sports Items', 'Football A', 'available'),
            ('Football', 'Sports Items', 'Football B', 'available'),
            ('Football', 'Sports Items', 'Football C', 'available'),
            ('Frisbee', 'Sports Items', 'Frisbee A', 'available'),
            ('Frisbee', 'Sports Items', 'Frisbee B', 'available'),
            ('Frisbee', 'Sports Items', 'Frisbee C', 'available'),
            ('Tennis Racket', 'Sports Items', 'Tennis Racket A', 'available'),
            ('Tennis Racket', 'Sports Items', 'Tennis Racket B', 'available'),
            ('Tennis Racket', 'Sports Items', 'Tennis Racket C', 'available'),

            ('Speaker', 'Electronics', 'Speaker A', 'available'),
            ('Speaker', 'Electronics', 'Speaker B', 'available'),
            ('Speaker', 'Electronics', 'Speaker C', 'available'),
            ('PS5 Controller', 'Electronics', 'PS5 Controller A', 'available'),
            ('PS5 Controller', 'Electronics', 'PS5 Controller B', 'available'),
            ('PS5 Controller', 'Electronics', 'PS5 Controller C', 'available'),
            ('Headphones', 'Electronics', 'Headphones A', 'available'),
            ('Headphones', 'Electronics', 'Headphones B', 'available'),
            ('Headphones', 'Electronics', 'Headphones C', 'available'),
            ('Nintendo Switch', 'Electronics', 'Nintendo Switch A', 'available'),
            ('Nintendo Switch', 'Electronics', 'Nintendo Switch B', 'available'),
            ('Nintendo Switch', 'Electronics', 'Nintendo Switch C', 'available'),
            ('Gameboy', 'Electronics', 'Gameboy A', 'available'),
            ('Gameboy', 'Electronics', 'Gameboy B', 'available'),
            ('Gameboy', 'Electronics', 'Gameboy C', 'available');
        """

        cursor.execute(sql_query)
        db.commit()
        print("Successfully added all item versions to the database")
        
    except pymysql.Error as e:
        print(f"Error inserting items: {e}")
        db.rollback()

    finally:
        db.close()


# Add Rooms to Database
def seed_rooms():
    db = get_db_connection()

    if not db:
        print("Could not connect to the database")
        return

    try:
        cursor = db.cursor()
        
        sql_query = """
            INSERT INTO rooms (name, capacity, status) VALUES
            ('Study Room', 4, 'available'),
            ('Meeting Room', 10, 'available'),
            ('Studio Room', 4, 'available'),
            ('Practice Room', 2, 'available'),
            ('Cinema Room', 15, 'available');
        """
        
        cursor.execute(sql_query)
        db.commit()
        print("Successfully added all rooms to the database")
        
    except pymysql.Error as e:
        print(f"Error inserting rooms: {e}")
        db.rollback()

    finally:
        db.close()

if __name__ == "__main__":
    seed_items()
    seed_rooms()