"""Shows each bundle ID's capabilities and deletes stale Xcode-managed provisioning profiles for this
app, so automatic signing regenerates them with the current capabilities (e.g. App Groups).
Uses the App Store Connect API key from env: KEY, ISSUER, P8_PATH. Prints no secrets."""
import json, os, sys, time, urllib.request, urllib.parse
import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com/v1"
IDS = ["com.robertlangat.thingstodonext", "com.robertlangat.thingstodonext.todaywidget", "com.robertlangat.thingstodonext.watchkitapp"]

key = open(os.environ["P8_PATH"]).read()
now = int(time.time())
token = jwt.encode({"iss": os.environ["ISSUER"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                   key, algorithm="ES256", headers={"kid": os.environ["KEY"], "typ": "JWT"})

def call(method, path):
    req = urllib.request.Request(API + path, method=method, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        print(f"  API {method} {path.split('?')[0]} -> {e.code}: {e.read()[:300]!r}")
        return None

for ident in IDS:
    q = urllib.parse.urlencode({"filter[identifier]": ident, "include": "bundleIdCapabilities", "limit": 20})
    res = call("GET", f"/bundleIds?{q}") or {}
    match = [b for b in res.get("data", []) if b["attributes"]["identifier"] == ident]
    if not match:
        print(f"{ident}: NOT REGISTERED yet (automatic signing will register it)")
        continue
    caps = sorted({c["attributes"]["capabilityType"] for c in res.get("included", [])
                   if c["type"] == "bundleIdCapabilities" and c["id"].startswith(match[0]["id"])})
    print(f"{ident}: capabilities = {', '.join(caps) or '(none)'}")
    if ident != IDS[2] and "APP_GROUPS" not in caps:
        print(f"::warning::{ident} does not have the App Groups capability enabled.")

q = urllib.parse.urlencode({"limit": 200, "fields[profiles]": "name,profileState"})
profiles = (call("GET", f"/profiles?{q}") or {}).get("data", [])
for p in profiles:
    name = p["attributes"]["name"]
    if any(name.endswith(": " + i) or name.endswith(i) for i in IDS) and "Team Provisioning Profile" in name:
        r = call("DELETE", f"/profiles/{p['id']}")
        print(f"deleted stale profile: {name}" if r is not None else f"could not delete: {name}")
