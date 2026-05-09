# %% [markdown]
# # Download, Decompress, Parse, Insert into Database, and Delete

# %%
import psycopg2
import os
import shutil
import sys
import datetime

# redirect the output to a log file
logname = (
    "logs/" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S") + "_wiki240201" + ".log"
)
log = open(logname, "a")
sys.stdout = log

errname = (
    "logs/" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S") + "_wiki240201" + ".err"
)
err = open(errname, "a")
sys.stderr = err
import requests
from concurrent.futures import ThreadPoolExecutor
import pandas as pd
import py7zr

# Database connection details
db_host = "localhost"
db_port = "5432"
db_name = "wiki240201"
db_user = "richard"
db_password = "rich"

import mwxml
import time
import tqdm


# %%
def download_file(url, filename):
    response = requests.get(url, stream=True)
    while response.status_code != 200:
        print(f"Error: {response.status_code}. Retrying in 60 seconds.", flush=True)
        time.sleep(60)
        response = requests.get(url, stream=True)
    with open(filename, "wb") as file:
        for chunk in response.iter_content(chunk_size=1024):
            if chunk:
                file.write(chunk)
    print(f"Downloaded: {filename}", flush=True)


def decompress_file(filename):
    with py7zr.SevenZipFile(filename, mode="r") as archive:
        archive.extractall()
    print(f"Decompressed: {filename}", flush=True)


def insert_db(data_list):
    status = False
    try:
        # Connect to the database
        conn = psycopg2.connect(
            host=db_host,
            port=db_port,
            dbname=db_name,
            user=db_user,
            password=db_password,
        )

        # Create a cursor object
        cur = conn.cursor()

        # Create the tables (same as before)
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY,
                text VARCHAR NULL,
                deleted BOOLEAN DEFAULT FALSE
            );
        """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS pages (
                id INTEGER PRIMARY KEY,
                title VARCHAR NULL,
                namespace INTEGER NULL,
                restrictions JSONB NULL,
                deleted BOOLEAN DEFAULT FALSE
            );
        """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS revisions (
                id INTEGER PRIMARY KEY,
                timestamp TIMESTAMP NULL,
                user_id INTEGER NULL REFERENCES users(id),
                page_id INTEGER NULL REFERENCES pages(id),
                minor BOOLEAN NULL,
                comment TEXT NULL,
                text TEXT NULL,
                bytes INTEGER NULL,
                sha1 VARCHAR NULL,
                model VARCHAR NULL,
                format VARCHAR NULL,
                deleted_text BOOLEAN DEFAULT FALSE,
                deleted_comment BOOLEAN DEFAULT FALSE,
                deleted_user BOOLEAN DEFAULT FALSE
            );
        """
        )
        # Insert user data
        user_data = [
            (
                d.get("user", {}).get("id"),
                d.get("user", {}).get("text"),
                d.get("deleted", {}).get("user"),
            )
            for d in data_list
            if d.get("user", {}).get("id") is not None
        ]
        cur.executemany(
            """
            INSERT INTO users (id, text, deleted)
            VALUES (%s, %s, %s)
            ON CONFLICT (id) DO NOTHING;
        """,
            user_data,
        )

        # Insert page data
        page_data = [
            (
                d.get("page", {}).get("id"),
                d.get("page", {}).get("title"),
                d.get("page", {}).get("namespace"),
                d.get("page", {}).get("restrictions"),
                False,
            )
            for d in data_list
            if d.get("page", {}).get("id") is not None
        ]
        cur.executemany(
            """
            INSERT INTO pages (id, title, namespace, restrictions, deleted)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (id) DO NOTHING;
        """,
            page_data,
        )

        # Insert revision data
        revision_data = [
            (
                d.get("id"),
                d.get("timestamp"),
                d.get("user", {}).get("id"),
                d.get("page", {}).get("id"),
                d.get("minor"),
                d.get("comment"),
                d.get("text"),
                d.get("bytes"),
                d.get("sha1"),
                d.get("model"),
                d.get("format"),
                d.get("deleted", {}).get("text"),
                d.get("deleted", {}).get("comment"),
                d.get("deleted", {}).get("user"),
            )
            for d in data_list
            if d.get("id") is not None
        ]
        cur.executemany(
            """
            INSERT INTO revisions (id, timestamp, user_id, page_id, minor, comment, text, bytes, sha1, model, format, deleted_text, deleted_comment, deleted_user)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (id) DO NOTHING;
        """,
            revision_data,
        )

        # Commit the changes
        conn.commit()
        status = True
        print("\t\t\tData inserted successfully.", flush=True)

    except psycopg2.Error as e:
        # Handle any errors that occur during the database operations
        print(f"\t\t\tAn error occurred: {e}", flush=True)
        conn.rollback()

    finally:
        # Close the cursor and the database connection
        if cur:
            cur.close()
        if conn:
            conn.close()
        return status


def parse_insert(dump_name):
    print(
        f"Start Dump {dump_name}. Time: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}"
    )
    dump = mwxml.Dump.from_file(open(dump_name, "rb"))
    data_list = []
    total_number = 0
    part_number = 0

    for page in dump:
        if page.namespace in [1, 3, 5, 7, 9, 11, 13, 101, 119, 711, 829, 2301, 2303]:
            for revision in page:
                data_dict = revision.to_json()
                data_list.append(data_dict)
                part_number += 1
        if part_number >= 1000:
            print(
                f"\t\t\tInserting {part_number} records. Total: {total_number + part_number}",
                flush=True,
            )
            insert_db(data_list)
            print(
                f"\t\t\tInserted {part_number} records. Total: {total_number + part_number}",
                flush=True,
            )
            time.sleep(1)
            print(
                f"\t\t\tCurrent Time: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}",
                flush=True,
            )
            total_number += part_number
            data_list = []
            part_number = 0

    if data_list:
        insert_db(data_list)
        print(
            f"\t\t\tInserted {part_number} records. Total: {total_number + part_number}",
            flush=True,
        )
        time.sleep(5)
        print(
            f"\t\t\tCurrent Time: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}",
            flush=True,
        )
        total_number += part_number
        data_list = []
        total_number += part_number

    print(
        f"Completed Dump {dump_name}. Total: {total_number} records. Time: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}"
    )


def delete_file(dump_name):
    os.remove(dump_name)
    print(f"Deleted: {dump_name}")


def move_file_to_finished_directory(dump_name):
    source_file = dump_name + ".7z"
    destination_directory = "finished"
    shutil.move(source_file, destination_directory)
    print(f"Moved {source_file} to {destination_directory} directory.")


def ddpid(url):
    filename = url.split("/")[-1]
    download_file(url, filename)
    decompress_file(filename)
    dump_file_name = filename[:-3]
    parse_insert(dump_file_name)
    delete_file(dump_file_name)
    move_file_to_finished_directory(dump_file_name)


# %%
if __name__ == "__main__":
    finished = os.listdir("finished")
    dump_names_df = pd.read_csv("wiki240201.csv", header=None)
    dump_names = dump_names_df[0].to_list()
    urls = [
        "https://dumps.wikimedia.org/enwiki/20240201/" + i
        for i in dump_names
        if i not in finished
    ]


with tqdm.tqdm(total=len(urls)) as pbar:
    with ThreadPoolExecutor() as executor:
        for _ in executor.map(ddpid, urls):
            pbar.update(1)
