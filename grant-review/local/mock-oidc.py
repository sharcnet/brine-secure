#!/usr/bin/env python3
"""A mock OIDC provider that stands in for CILogon on the local Lima test VM. NEVER on a real VM.

It signs in whoever the test harness says is next, with whatever claims it chooses, so the
acceptance tests can check that the review VM refuses the wrong IdP, a missing MFA claim, a
non-Alliance eppn, and pending or removed reviewers.

  python3 mock-oidc.py --issuer http://192.168.64.2:9000 --client-id ID --client-secret-file F

Endpoints: the usual discovery, /authorize, /token, /userinfo, /jwks, plus test controls:
  POST /test/next   JSON claims for the next sign-in, e.g.
                    {"eppn": "testa@alliancecan.ca", "idp": "https://idp.alliancecan.ca/idp/shibboleth",
                     "acr": "https://refeds.org/profile/mfa"}   (a null value leaves the claim out)
  GET  /test/last   the query parameters of the last /authorize request
Needs python3-jwt and python3-cryptography (Ubuntu packages).
"""
import argparse
import base64
import hashlib
import json
import secrets
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

ap = argparse.ArgumentParser()
ap.add_argument("--issuer", required=True)
ap.add_argument("--listen", default="0.0.0.0:9000")
ap.add_argument("--client-id", required=True)
ap.add_argument("--client-secret-file", required=True)
ap.add_argument("--ttl", type=int, default=900, help="ID and access token lifetime, seconds")
args = ap.parse_args()
SECRET = open(args.client_secret_file).read().strip()
ISS = args.issuer.rstrip("/")

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
KID = secrets.token_hex(4)
pub = KEY.public_key().public_numbers()
b64 = lambda n: base64.urlsafe_b64encode(n.to_bytes((n.bit_length() + 7) // 8, "big")).rstrip(b"=").decode()
JWKS = {"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": KID, "n": b64(pub.n), "e": b64(pub.e)}]}

lock = threading.Lock()
state = {"next": None, "last": {}, "codes": {}, "tokens": {}}


def claims_for(ident, client_id, nonce):
    now = int(time.time())
    c = {"iss": ISS, "aud": client_id, "sub": "http://cilogon.org/serverT/users/" + str(abs(hash(ident.get("eppn"))) % 10**6),
         "iat": now, "exp": now + args.ttl, "auth_time": now, "name": "Test Reviewer"}
    if nonce:
        c["nonce"] = nonce
    for k, v in ident.items():
        if v is not None:
            c[k] = v
    return c


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        pass

    def send(self, code, body=b"", ctype="application/json", headers=()):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def form(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode()
        if self.headers.get("Content-Type", "").startswith("application/json"):
            return json.loads(raw or "{}")
        return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        if u.path == "/.well-known/openid-configuration":
            return self.send(200, {
                "issuer": ISS, "authorization_endpoint": ISS + "/authorize", "token_endpoint": ISS + "/token",
                "userinfo_endpoint": ISS + "/userinfo", "jwks_uri": ISS + "/jwks",
                "response_types_supported": ["code"], "subject_types_supported": ["public"],
                "id_token_signing_alg_values_supported": ["RS256"], "code_challenge_methods_supported": ["S256"],
                "scopes_supported": ["openid", "email", "profile", "org.cilogon.userinfo"],
                "token_endpoint_auth_methods_supported": ["client_secret_basic", "client_secret_post"]})
        if u.path == "/jwks":
            return self.send(200, JWKS)
        if u.path == "/test/last":
            with lock:
                return self.send(200, state["last"])
        if u.path == "/authorize":
            with lock:
                state["last"] = q
                ident = state["next"]
            if q.get("client_id") != args.client_id or not q.get("redirect_uri"):
                return self.send(400, {"error": "bad client or redirect_uri"})
            if ident is None:
                return self.send(403, {"error": "no identity queued (POST /test/next first)"})
            code = secrets.token_urlsafe(24)
            with lock:
                state["codes"][code] = {"ident": ident, "nonce": q.get("nonce"), "redirect_uri": q["redirect_uri"],
                                        "challenge": q.get("code_challenge"), "method": q.get("code_challenge_method")}
            sep = "&" if "?" in q["redirect_uri"] else "?"
            loc = q["redirect_uri"] + sep + urllib.parse.urlencode({"code": code, "state": q.get("state", "")})
            return self.send(302, b"", "text/plain", [("Location", loc)])
        if u.path == "/userinfo":
            tok = self.headers.get("Authorization", "")[7:]
            with lock:
                c = state["tokens"].get(tok)
            return self.send(200, c) if c else self.send(401, {"error": "invalid_token"})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/test/next":
            with lock:
                state["next"] = self.form()
            return self.send(200, {"ok": True})
        if u.path == "/token":
            f = self.form()
            cid, csec = f.get("client_id"), f.get("client_secret")
            auth = self.headers.get("Authorization", "")
            if auth.startswith("Basic "):
                cid, csec = [urllib.parse.unquote(x) for x in base64.b64decode(auth[6:]).decode().split(":", 1)]
            if cid != args.client_id or csec != SECRET:
                return self.send(401, {"error": "invalid_client"})
            with lock:
                c = state["codes"].pop(f.get("code", ""), None)
            if not c or c["redirect_uri"] != f.get("redirect_uri"):
                return self.send(400, {"error": "invalid_grant"})
            if c["challenge"]:
                v = f.get("code_verifier", "")
                calc = base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b"=").decode()
                if c["method"] != "S256" or calc != c["challenge"]:
                    return self.send(400, {"error": "invalid_grant", "error_description": "PKCE"})
            claims = claims_for(c["ident"], cid, c["nonce"])
            idt = jwt.encode(claims, KEY, algorithm="RS256", headers={"kid": KID})
            at = secrets.token_urlsafe(24)
            with lock:
                state["tokens"][at] = {k: v for k, v in claims.items() if k not in ("aud", "nonce", "iat", "exp")}
            return self.send(200, {"access_token": at, "token_type": "Bearer", "expires_in": args.ttl, "id_token": idt})
        self.send(404, {"error": "not found"})


host, port = args.listen.rsplit(":", 1)
print(f"mock OIDC provider {ISS} on {args.listen}", flush=True)
ThreadingHTTPServer((host, int(port)), H).serve_forever()
