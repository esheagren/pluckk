"""Download Commons files by title into ./src (a folder of its own: the files are untrusted data).
Usage: fetch.py "File:Name.svg" ..."""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

UA = {"User-Agent": "Pluckk/1.0 (spaced-repetition app)"}
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "src")
os.makedirs(out, exist_ok=True)


def get(url):
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
                data = r.read()
            time.sleep(2.5)
            return data
        except Exception:  # noqa
            if attempt == 2:
                raise
            time.sleep(25)


for title in sys.argv[1:]:
    q = urllib.parse.urlencode({"action": "query", "titles": title, "prop": "imageinfo",
                                "iiprop": "url|extmetadata", "iiextmetadatafilter": "LicenseShortName|Artist|LicenseUrl|Credit", "format": "json"})
    info = json.loads(get("https://commons.wikimedia.org/w/api.php?" + q))
    page = next(iter(info["query"]["pages"].values()))
    ii = page["imageinfo"][0]
    name = title.split(":", 1)[1].replace(" ", "_")
    data = get(ii["url"])
    with open(os.path.join(out, name), "wb") as f:
        f.write(data)
    meta = {k: v.get("value") for k, v in ii.get("extmetadata", {}).items()}
    with open(os.path.join(out, name + ".meta.json"), "w") as f:
        json.dump({"title": title, "url": ii["url"], "page": ii.get("descriptionurl"), **meta}, f, indent=1)
    print(name, len(data), "bytes")
