"""OpenRouter-free-first, local-fallback shim for /v1/chat/completions.

Registered in llama-swap as peer "orfree" (model "auto"). Tries each model in
ORFREE_MODELS on OpenRouter; on any non-2xx / timeout / error body *before a
byte reaches the client*, replays the same body to the local llama-swap with
model=ORFREE_LOCAL_MODEL. Response header X-Route: openrouter|local.

Model "overflow" (SEI-279): local while the local model is idle; OpenRouter only
while it is busy (a slot is processing) or not loaded, so callers skip the queue.
A request whose body looks like it carries a credential never leaves the host.
"""
import http.client, json, os, re, ssl, sys, time, threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

E = os.environ.get
PORT = int(E("ORFREE_PORT", "8795"))
UPSTREAM = E("ORFREE_UPSTREAM", "https://openrouter.ai/api")
KEY = E("OPENROUTER_API_KEY", "")
MODELS = [x for x in E("ORFREE_MODELS", "").split(",") if x]
LOCAL = E("ORFREE_LOCAL_URL", "http://127.0.0.1:8888")
LOCAL_MODEL = E("ORFREE_LOCAL_MODEL", "chat")
HDR_TIMEOUT = float(E("ORFREE_HEADER_TIMEOUT", "30"))
# overflow callers (OpenViking extraction) are non-stream with ~1-6K output tokens.
OVERFLOW_HDR_TIMEOUT = float(E("ORFREE_OVERFLOW_HEADER_TIMEOUT", "120"))
# Real llama-swap model behind LOCAL_MODEL ("chat" alias); /running lists real names only.
BUSY_MODEL = E("ORFREE_BUSY_MODEL", "bonsai")
# ponytail: regex screen, not a DLP; catches common key/token shapes only.
SECRET_RE = re.compile(
    r"sk-or-v1-[0-9A-Za-z]{20,}|\bsk-(?:ant-|proj-)?[0-9A-Za-z_-]{20,}"
    r"|\bgh[pousr]_[0-9A-Za-z]{30,}|github_pat_[0-9A-Za-z_]{30,}|\bAKIA[0-9A-Z]{16}\b"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----|AGE-SECRET-KEY-1[0-9A-Z]{50,}|tskey-[a-z]+-[0-9A-Za-z-]{20,}"
    r"|Bearer\s+[0-9A-Za-z._-]{20,}"
    r"|(?i:(?:api[_-]?key|token|secret|password)\\?\"?\s*[:=]\s*\\?\"?[0-9A-Za-z._/+-]{16,})"
)
STREAM_TIMEOUT = 300

cool = {}  # model or "*" -> unix time until which OpenRouter is skipped
lock = threading.Lock()


def next_utc_midnight():
    n = datetime.now(timezone.utc)
    return (n + timedelta(days=1)).replace(hour=0, minute=0, second=1, microsecond=0).timestamp()


def cooldown(model, status, headers, body):
    """Set a cooldown after a failed OpenRouter call (429 / auth / credit)."""
    if status == 429:
        text = body.decode("utf-8", "replace").lower()
        if "per-day" in text or "per day" in text or "daily" in text:
            key, until = "*", next_utc_midnight()
        else:
            ra = headers.getheader("Retry-After") or ""
            key, until = model, time.time() + (float(ra) if ra.replace(".", "", 1).isdigit() else 60)
    elif status in (401, 402, 403):
        key, until = "*", time.time() + 300
    else:
        return
    with lock:
        cool[key] = max(cool.get(key, 0), until)


def cooling(model):
    now = time.time()
    return cool.get("*", 0) > now or cool.get(model, 0) > now


def open_get(base, path, timeout=5):
    u = urlsplit(base)
    c = http.client.HTTPConnection(u.netloc, timeout=timeout)
    c.request("GET", u.path.rstrip("/") + path)
    return c, c.getresponse()


def local_busy():
    """(busy, why): busy if BUSY_MODEL is processing or not loaded (a swap would queue too)."""
    try:
        c, r = open_get(LOCAL, "/running")
        running = {m.get("model"): m.get("state") for m in json.loads(r.read()).get("running", [])}
        c.close()
        if running.get(BUSY_MODEL) != "ready":
            return True, f"{BUSY_MODEL}-not-loaded"
        # Only asked once loaded: /upstream/<model>/ on a cold model would start a load.
        c, r = open_get(LOCAL, f"/upstream/{BUSY_MODEL}/slots")
        slots = json.loads(r.read())
        c.close()
        busy = any(s.get("is_processing") for s in slots)
        return busy, f"{BUSY_MODEL}-busy" if busy else f"{BUSY_MODEL}-idle"
    except (OSError, http.client.HTTPException, ValueError, AttributeError) as e:
        print(f"orfree: busy check failed, assuming idle: {e!r}", flush=True)
        return False, "busy-check-failed"


def open_upstream(base, path, body, headers, timeout):
    u = urlsplit(base)
    cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
    c = cls(u.netloc, timeout=timeout)
    c.request("POST", u.path.rstrip("/") + path, body, headers)
    return c, c.getresponse()  # raises on connect / header timeout


class H(BaseHTTPRequestHandler):
    # HTTP/1.0 + Connection: close => streamed bodies are EOF-delimited, no chunking code.
    def log_message(self, *a):
        pass

    def send_json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            self.send_json(200, {"object": "list", "data": [{"id": m, "object": "model", "owned_by": "orfree"} for m in ("auto", "overflow")]})
        elif self.path == "/health":
            self.send_json(200, {"ok": True})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        t0 = time.time()
        if self.path.split("?")[0] != "/v1/chat/completions":
            return self.send_json(404, {"error": "only /v1/chat/completions"})
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            req = json.loads(raw)
        except ValueError:
            return self.send_json(400, {"error": "invalid json"})
        stream = bool(req.get("stream"))
        hd = {"Content-Type": "application/json"}
        overflow = str(req.get("model", "")).endswith("overflow")
        hdr_timeout = OVERFLOW_HDR_TIMEOUT if overflow else HDR_TIMEOUT
        # trail = why this request ended where it did; sent as X-Route-Reason and logged.
        trail = ["overflow" if overflow else "auto"]
        if SECRET_RE.search(raw.decode("utf-8", "replace")):
            models = []
            trail.append("secret-in-body")
        elif overflow:
            busy, why = local_busy()
            models = MODELS if busy else []
            trail.append(why)
        else:
            models = MODELS
        if models and not KEY:
            models = []
            trail.append("no-key")

        for model in models:
            short = model.split("/")[-1]
            if cooling(model):
                trail.append(f"{short}:cooldown")
                continue
            body = json.dumps({**req, "model": model}).encode()
            try:
                c, r = open_upstream(UPSTREAM, "/v1/chat/completions", body, {**hd, "Authorization": "Bearer " + KEY}, hdr_timeout)
            except (OSError, http.client.HTTPException, ssl.SSLError) as e:
                print(f"orfree: {model} connect/header error: {e!r}", flush=True)
                trail.append(f"{short}:" + ("timeout" if isinstance(e, TimeoutError) else "conn-error"))
                continue
            if r.status // 100 != 2:
                b = r.read()
                cooldown(model, r.status, r, b)
                print(f"orfree: {model} -> {r.status} {b[:200]!r}", flush=True)
                trail.append(f"{short}:{r.status}")
                c.close()
                continue
            if not stream:  # OpenRouter may answer 200 with {"error": ...}
                try:
                    b = r.read()
                    ok = "error" not in json.loads(b)
                except (OSError, http.client.HTTPException, ValueError):
                    ok = False
                c.close()
                if not ok:
                    print(f"orfree: {model} -> 200 with error body", flush=True)
                    trail.append(f"{short}:error-body")
                    continue
                return self.reply(r, "openrouter", model, t0, trail + [f"{short}:ok"], body=b)
            try:
                c.sock.settimeout(STREAM_TIMEOUT)
            except AttributeError:
                pass
            return self.reply(r, "openrouter", model, t0, trail + [f"{short}:ok"], conn=c)

        # Local fallback.
        body = json.dumps({**req, "model": LOCAL_MODEL}).encode()
        try:
            # No timeout: llama-swap queues behind cold loads / busy bonsai (observed
            # 2-7 min on 2026-11-15; a 300 s cap 502ed). The caller owns the deadline.
            c, r = open_upstream(LOCAL, "/v1/chat/completions", body, hd, None)
        except (OSError, http.client.HTTPException) as e:
            print(f"orfree: local failed: {e!r} reason={' '.join(trail)}", flush=True)
            return self.send_json(502, {"error": f"openrouter exhausted and local failed: {e!r}"})
        self.reply(r, "local", LOCAL_MODEL, t0, trail + ["local"], conn=c)

    def reply(self, r, route, model, t0, trail, body=None, conn=None):
        reason = " ".join(trail)
        self.send_response(r.status)
        for k in ("Content-Type", "Cache-Control"):
            if r.getheader(k):
                self.send_header(k, r.getheader(k))
        self.send_header("X-Route", route)
        self.send_header("X-Route-Model", model)
        self.send_header("X-Route-Reason", reason)
        self.send_header("Connection", "close")
        if body is not None:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            if body is not None:
                self.wfile.write(body)
            else:
                while chunk := r.read1(8192):
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except (OSError, http.client.HTTPException) as e:
            print(f"orfree: stream aborted: {e!r}", flush=True)  # bytes already sent: cannot fall back
        finally:
            if conn:
                conn.close()
        print(f"orfree: route={route} model={model} status={r.status} ms={int((time.time() - t0) * 1000)} reason={reason}", flush=True)


if __name__ == "__main__":
    if not MODELS:
        sys.exit("ORFREE_MODELS is empty")
    print(f"orfree: listening 127.0.0.1:{PORT} models={MODELS} key={'set' if KEY else 'MISSING (local only)'}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
