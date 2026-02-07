#!/bin/bash
# Export records.db to CSV
DB="${1:-data/records.db}"
sqlite3 -header -csv "$DB" "SELECT id, number, artist, title, genre, year, artwork_path FROM records;"
