"""Shows each bundle ID's capabilities and deletes stale Xcode-managed provisioning profiles for this
app, so automatic signing regenerates them with the current capabilities (e.g. App Groups).
Uses the App Store Connect API key from env: KEY, ISSUER, P8_PATH. Prints no secrets."""
import json, os, sys, time, urllib.request, urllib.parse
import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com/v1"
IDS = ["com.robertlangat.thingstodonext", "com.robertlangat.thingstodonext.widget", "com.robertlangat.thingstodonext.watchkitapp"]

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

# Certificates: each CI run starts on a fresh Mac with no private keys, so automatic signing creates a
# new certificate every time ("Created via API"). Those are useless once the run ends. List them, and
# revoke them only when the workflow was started with revoke_ci_certs=true.
q = urllib.parse.urlencode({"limit": 200, "fields[certificates]": "name,displayName,certificateType,expirationDate"})
certs = (call("GET", f"/certificates?{q}") or {}).get("data", [])
print(f"certificates on the account: {len(certs)}")
for c in certs:
    a = c["attributes"]
    print(f"  CERT: {a.get('certificateType')} | {a.get('displayName') or a.get('name')} | expires {a.get('expirationDate', '')[:10]}")
if os.environ.get("REVOKE_CI_CERTS") == "true":
    for c in certs:
        a = c["attributes"]
        label = f"{a.get('name', '')} {a.get('displayName', '')}"
        keep = os.environ.get("KEEP_CERTS_EXPIRING", "")
        if keep and a.get("expirationDate", "").startswith(keep):
            print(f"  kept: {a.get('certificateType')} {a.get('displayName')} (expires {keep})")
            continue
        if "Created via API" in label and a.get("certificateType") == "DEVELOPMENT":
            r = call("DELETE", f"/certificates/{c['id']}")
            print(f"  revoked: {a.get('certificateType')} {a.get('displayName')}" if r is not None else f"  could not revoke {c['id']}")

q = urllib.parse.urlencode({"filter[bundleId]": IDS[0], "fields[apps]": "name,bundleId,sku"})
apps = call("GET", f"/apps?{q}")
if apps is None:
    print("::warning::Could not read apps. The API key may need the App Manager or Admin role.")
else:
    found = apps.get("data", [])
    print(f"App Store Connect app records for {IDS[0]}: " + (", ".join(a["attributes"]["name"] + " (id " + a["id"] + ")" for a in found) or "NONE"))
    for a in found:
        v = call("GET", f"/apps/{a['id']}/appStoreVersions?fields[appStoreVersions]=platform,versionString,appStoreState&limit=10")
        for x in (v or {}).get("data", []):
            print(f"  version: {x['attributes'].get('platform')} {x['attributes'].get('versionString')} {x['attributes'].get('appStoreState')}")
        b = call("GET", f"/builds?filter[app]={a['id']}&limit=3&fields[builds]=version,processingState")
        print("  builds readable by this key: " + ("yes" if b is not None else "NO (key role too low?)"))
