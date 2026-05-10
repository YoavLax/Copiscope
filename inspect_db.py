import sqlite3
import json

db_path = r'C:\Users\ylax\AppData\Roaming\Code\User\globalStorage\github.copilot-chat\agent-traces.db'
conn = sqlite3.connect(db_path)
c = conn.cursor()

# Get all tables
print("=== TABLES ===")
c.execute("SELECT name FROM sqlite_master WHERE type='table'")
tables = [r[0] for r in c.fetchall()]
print(tables)

# Get schema for each table
print("\n=== SCHEMAS ===")
for t in tables:
    c.execute(f"SELECT sql FROM sqlite_master WHERE name='{t}'")
    row = c.fetchone()
    if row:
        print(row[0])
        print()

# Sample a few rows from each table
for t in tables:
    print(f"\n=== SAMPLE: {t} (first 3 rows) ===")
    c.execute(f"SELECT * FROM {t} LIMIT 3")
    cols = [d[0] for d in c.description]
    print("Columns:", cols)
    for row in c.fetchall():
        for col, val in zip(cols, row):
            display = str(val)[:200] if val else str(val)
            print(f"  {col}: {display}")
        print("  ---")

# Count rows
print("\n=== ROW COUNTS ===")
for t in tables:
    c.execute(f"SELECT COUNT(*) FROM {t}")
    print(f"{t}: {c.fetchone()[0]}")

conn.close()
