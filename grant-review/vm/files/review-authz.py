#!/usr/bin/python3 -I
"""review-authz: the last check before nginx picks a reviewer's socket (WEB_AUTH=sso).

nginx sends every reviewer request here first (auth_request). This asks oauth2-proxy whether
the session cookie is valid, then reads the ID token oauth2-proxy verified at sign-in and
checks, itself:
  - idp  is the Alliance IdP (SSO_IDP); CILogon's idphint is only a hint,
  - acr  is MFA (SSO_MFA),
  - eppn is <name>@SSO_DOMAIN, and <name> is a valid username on the active list.
Only then does it answer 202 with X-Review-User: <name>. Anything else is 401 (not signed in)
or 403 (signed in, not allowed), or 500 on an error. It never fails open: any error is a refusal.

The ID token's signature isn't checked again here: it comes from oauth2-proxy's encrypted
session over loopback, and oauth2-proxy verified it at sign-in. Its exp isn't checked either:
CILogon ID tokens last minutes, and the session's length is oauth2-proxy's cookie_expire.

Python standard library only. Listens on 127.0.0.1:4181. Logs names and reasons, never URLs.
"""
import base64
import http.client
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

IDP = os.environ["SSO_IDP"]
MFA = os.environ["SSO_MFA"]
DOMAIN = os.environ["SSO_DOMAIN"]
ACTIVE = os.environ.get("ACTIVE_FILE", "/etc/brine-review/web/active")
O2P = ("127.0.0.1", 4180)
EPPN = re.compile(r"^([a-z][a-z0-9_-]{0,30})@" + re.escape(DOMAIN) + r"$")

_active = {"mtime": None, "names": frozenset()}


def active_names():
    """The active list, re-read whenever the file changes. Missing or unreadable: nobody."""
    try:
        m = os.stat(ACTIVE).st_mtime_ns
        if m != _active["mtime"]:
            with open(ACTIVE) as f:
                names = frozenset(l.strip() for l in f if re.fullmatch(r"[a-z][a-z0-9_-]{0,30}", l.strip()))
            _active.update(mtime=m, names=names)
        return _active["names"]
    except OSError:
        return frozenset()


def payload(jwt):
    p = jwt.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))


def log(msg):
    print(msg, file=sys.stderr, flush=True)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # no request lines: they would hold URLs
        pass

    def answer(self, code, user=None):
        self.send_response(code)
        if user:
            self.send_header("X-Review-User", user)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        try:
            conn = http.client.HTTPConnection(*O2P, timeout=5)
            hdrs = {"Host": self.headers.get("Host", "review")}
            for h in ("Cookie", "X-Real-IP", "X-Forwarded-For", "X-Forwarded-Proto", "X-Forwarded-Host"):
                if self.headers.get(h):
                    hdrs[h] = self.headers[h]
            conn.request("GET", "/oauth2/auth", headers=hdrs)
            r = conn.getresponse()
            r.read()
            if r.status == 401:
                return self.answer(401)
            if r.status != 202:
                return self.answer(403)
            claims = payload(r.getheader("X-Auth-Request-Id-Token", ""))
            eppn = claims.get("eppn", "")
            acr = claims.get("acr")
            acrs = acr if isinstance(acr, list) else [acr]
            m = EPPN.match(eppn) if isinstance(eppn, str) else None
            why = None
            if claims.get("idp") != IDP:
                why = "idp is not the Alliance IdP"
            elif MFA not in acrs:
                why = "no MFA in acr"
            elif not m:
                why = "eppn is not <username>@" + DOMAIN
            elif r.getheader("X-Auth-Request-Email", "") != eppn:
                why = "session email and ID token eppn differ"
            elif m.group(1) not in active_names():
                why = "not an active reviewer"
            if why:
                log(f"denied {eppn if m else '?'}: {why}")
                return self.answer(403)
            return self.answer(202, m.group(1))
        except Exception as e:  # fail closed; 500 lets nginx say sign-in is unavailable
            log(f"error: {type(e).__name__}")
            return self.answer(500)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 4181), H).serve_forever()
