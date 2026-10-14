#!/usr/bin/env python3
"""Upload build artifacts to a Google Drive folder via a service account.

Each run creates (or reuses) a subfolder in the target folder named after the
build (VERSION_SLUG), shares the subfolder ("anyone with the link can view"),
uploads every file from UPLOAD_DIR into it, then deletes the oldest subfolders
so only the newest KEEP versions remain.

Environment:
  GOOGLE_SERVICE_ACCOUNT_JSON  service-account key JSON (raw string)   [required]
  GDRIVE_FOLDER_ID             id of the parent folder                  [required]
  UPLOAD_DIR                   directory with the files to upload      [default: artifacts]
  VERSION_SLUG                 subfolder name for this build           [required]
  KEEP                         number of version folders to retain     [default: 3]
  LINK_OUTPUT                  markdown link list output file          [default: drive_links.md]
"""

import json
import os
import sys

import requests
from google.auth.transport.requests import Request
from google.oauth2 import service_account

FILES_API = "https://www.googleapis.com/drive/v3/files"
UPLOAD_API = "https://www.googleapis.com/upload/drive/v3/files"
SCOPE = ["https://www.googleapis.com/auth/drive"]


def fail(msg):
    print(f"::error::{msg}", file=sys.stderr)
    sys.exit(1)


def auth_headers():
    raw = os.environ.get("GOOGLE_SERVICE_ACCOUNT_JSON", "")
    if not raw.strip():
        fail("GOOGLE_SERVICE_ACCOUNT_JSON is empty or missing")
    try:
        info = json.loads(raw)
    except json.JSONDecodeError as e:
        fail(f"GOOGLE_SERVICE_ACCOUNT_JSON is not valid JSON: {e}")
    creds = service_account.Credentials.from_service_account_info(info, scopes=SCOPE)
    creds.refresh(Request())
    return {
        "Authorization": f"Bearer {creds.token}",
        "Content-Type": "application/json; charset=UTF-8",
    }


def share_anyone_reader(session, headers, file_id, label):
    perm = session.post(
        f"{FILES_API}/{file_id}/permissions",
        params={"supportsAllDrives": "true"},
        headers=headers,
        data=json.dumps({"role": "reader", "type": "anyone"}),
    )
    if perm.status_code not in (200, 201):
        print(f"::warning::share returned {perm.status_code} for {label}: {perm.text}")


def find_or_create_folder(session, headers, parent_id, name):
    q = (
        f"name = '{name}' and '{parent_id}' in parents and "
        "mimeType = 'application/vnd.google-apps.folder' and trashed = false"
    )
    r = session.get(
        FILES_API,
        headers=headers,
        params={
            "q": q,
            "fields": "files(id)",
            "pageSize": 1,
            "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
        },
    )
    if r.status_code != 200:
        fail(f"folder lookup failed: {r.status_code} {r.text}")
    files = r.json().get("files", [])
    if files:
        folder_id = files[0]["id"]
    else:
        r = session.post(
            FILES_API,
            params={"supportsAllDrives": "true"},
            headers=headers,
            data=json.dumps(
                {
                    "name": name,
                    "mimeType": "application/vnd.google-apps.folder",
                    "parents": [parent_id],
                }
            ),
        )
        if r.status_code not in (200, 201):
            fail(f"folder create failed: {r.status_code} {r.text}")
        folder_id = r.json()["id"]

    share_anyone_reader(session, headers, folder_id, f"folder {name}")
    return folder_id


def upload_file(session, headers, folder_id, path):
    filename = os.path.basename(path)
    size = os.path.getsize(path)
    meta = {"name": filename, "parents": [folder_id]}

    init = session.post(
        UPLOAD_API,
        params={
            "uploadType": "resumable",
            "fields": "id,size,webViewLink",
            "supportsAllDrives": "true",
        },
        headers=headers,
        data=json.dumps(meta),
    )
    if init.status_code != 200:
        fail(f"upload init failed for {filename}: {init.status_code} {init.text}")
    location = init.headers.get("Location")
    if not location:
        fail(f"no upload Location header for {filename}")

    with open(path, "rb") as fh:
        up = session.put(
            location,
            headers={
                "Content-Type": "application/octet-stream",
                "Content-Length": str(size),
            },
            data=fh,
        )
    if up.status_code not in (200, 201):
        fail(f"upload failed for {filename}: {up.status_code} {up.text}")
    data = up.json()
    file_id = data["id"]
    view = data.get("webViewLink") or f"https://drive.google.com/file/d/{file_id}/view?usp=sharing"

    share_anyone_reader(session, headers, file_id, filename)
    return filename, view, int(data.get("size", size))


def prune_folders(session, headers, parent_id, keep):
    q = (
        f"'{parent_id}' in parents and "
        "mimeType = 'application/vnd.google-apps.folder' and trashed = false"
    )
    r = session.get(
        FILES_API,
        headers=headers,
        params={
            "q": q,
            "orderBy": "createdTime desc",
            "fields": "files(id,name,createdTime)",
            "pageSize": 100,
            "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
        },
    )
    if r.status_code != 200:
        fail(f"prune list failed: {r.status_code} {r.text}")
    folders = r.json().get("files", [])
    pruned_any = False
    for f in folders[keep:]:
        d = session.delete(
            f"{FILES_API}/{f['id']}",
            params={"supportsAllDrives": "true"},
            headers=headers,
        )
        if d.status_code not in (200, 204):
            # Fall back to moving to trash if direct delete is restricted
            t = session.patch(
                f"{FILES_API}/{f['id']}",
                params={"supportsAllDrives": "true"},
                headers=headers,
                data=json.dumps({"trashed": True}),
            )
            if t.status_code in (200, 204):
                print(f"trashed old version folder: {f['name']}")
                pruned_any = True
            else:
                print(f"::warning::could not remove old folder {f['name']}: {d.status_code}")
        else:
            print(f"pruned old version folder: {f['name']}")
            pruned_any = True

    if pruned_any:
        session.delete(f"{FILES_API}/trash", headers=headers)


def main():
    parent_id = os.environ.get("GDRIVE_FOLDER_ID", "").strip()
    slug = os.environ.get("VERSION_SLUG", "").strip()
    upload_dir = os.environ.get("UPLOAD_DIR", "artifacts")
    link_out = os.environ.get("LINK_OUTPUT", "drive_links.md")
    keep = int(os.environ.get("KEEP", "3"))

    if not parent_id:
        fail("GDRIVE_FOLDER_ID is missing")
    if not slug:
        fail("VERSION_SLUG is missing")

    session = requests.Session()
    headers = auth_headers()

    folder_id = find_or_create_folder(session, headers, parent_id, slug)
    folder_url = f"https://drive.google.com/drive/folders/{folder_id}?usp=sharing"
    print(f"version folder id: {folder_id} ({folder_url})")

    paths = sorted(
        os.path.join(upload_dir, f)
        for f in os.listdir(upload_dir)
        if os.path.isfile(os.path.join(upload_dir, f))
    )
    if not paths:
        fail(f"no files found in {upload_dir}")

    lines = [f"📁 [**Folder · Все файлы ({slug})**]({folder_url})"]
    for path in paths:
        name, url, size = upload_file(session, headers, folder_id, path)
        mb = round(size / 1024 / 1024, 1)
        lines.append(f"• [`{name}`]({url}) — {mb} MB")
        print(f"uploaded {name} ({mb} MB)")

    with open(link_out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    prune_folders(session, headers, parent_id, keep)
    print("done")


if __name__ == "__main__":
    main()
