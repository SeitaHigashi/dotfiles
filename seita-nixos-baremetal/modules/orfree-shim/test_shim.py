"""Self-check: fake OpenRouter + fake local, real shim. Run: python3 test_shim.py"""
import json, os, subprocess, sys, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

LOCAL_STATE = {"loaded": True, "busy": False}  # what the fake llama-swap reports

def fake(tag, fail):
    class F(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):  # llama-swap /running + /upstream/bonsai/slots
            if self.path == "/running":
                b = {"running": [{"model": "bonsai", "state": "ready"}] if LOCAL_STATE["loaded"] else []}
            else:
                assert LOCAL_STATE["loaded"], "slots asked while not loaded"
                b = [{"id": 0, "is_processing": LOCAL_STATE["busy"]}]
            self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(b).encode())
        def do_POST(self):
            req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if fail(req):
                self.send_response(429); self.send_header("Retry-After", "1"); self.end_headers(); self.wfile.write(b"{}"); return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream" if req.get("stream") else "application/json")
            self.end_headers()
            out = [b"data: " + tag.encode() + b"\n\n", b"data: [DONE]\n\n"] if req.get("stream") else [json.dumps({"tag": tag, "model": req["model"]}).encode()]
            for o in out: self.wfile.write(o); self.wfile.flush()
    s = HTTPServer(("127.0.0.1", 0), F); threading.Thread(target=s.serve_forever, daemon=True).start()
    return s.server_port

orp = fake("or", lambda r: r["model"] == "bad:free")
loc = fake("local", lambda r: False)
env = {**os.environ, "ORFREE_PORT": "18795", "OPENROUTER_API_KEY": "k", "ORFREE_MODELS": "good:free",
       "ORFREE_UPSTREAM": f"http://127.0.0.1:{orp}", "ORFREE_LOCAL_URL": f"http://127.0.0.1:{loc}"}
def run(models):
    p = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(__file__), "shim.py")], env={**env, "ORFREE_MODELS": models}); time.sleep(1); return p
def call(stream, model="auto", **extra):
    r = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:18795/v1/chat/completions", json.dumps({"model": model, "stream": stream, **extra}).encode(), {"Content-Type": "application/json"}))
    LAST["reason"] = r.headers["X-Route-Reason"]
    return r.headers["X-Route"], r.read()
LAST = {}
p = run("good:free")
try:
    assert call(False)[0] == "openrouter" and b'"good:free"' in call(False)[1]
    r, b = call(True); assert r == "openrouter" and b"[DONE]" in b
    # overflow: idle local -> local; busy or not loaded -> OpenRouter
    assert LAST["reason"] == "auto good:free:ok", LAST
    for loaded, busy, want, why in ((True, False, "local", "overflow bonsai-idle local"),
                                    (True, True, "openrouter", "overflow bonsai-busy good:free:ok"),
                                    (False, False, "openrouter", "overflow bonsai-not-loaded good:free:ok")):
        LOCAL_STATE.update(loaded=loaded, busy=busy)
        assert call(False, "orfree/overflow")[0] == want, (loaded, busy, want)
        assert LAST["reason"] == why, LAST
    LOCAL_STATE.update(loaded=True, busy=False)
    # hybrid: OpenRouter first even when local is idle; secrets stay local
    assert call(False, "orfree/hybrid")[0] == "openrouter" and LAST["reason"] == "hybrid good:free:ok", LAST
    r, b = call(False, "orfree/hybrid", messages=[{"role": "user", "content": "ghp_" + "B" * 36}])
    assert r == "local" and LAST["reason"] == "hybrid secret-in-body local", LAST
    # credentials never go to OpenRouter, in any mode
    for secret in ("sk-or-v1-" + "a" * 64, "ghp_" + "B" * 36, 'api_key: "abcdefghijklmnop1234"'):
        r, b = call(False, messages=[{"role": "user", "content": "x " + secret}])
        assert r == "local" and LAST["reason"] == "auto secret-in-body local", (secret, LAST)
    assert call(False, messages=[{"role": "user", "content": "max_tokens: 6144, api_key: llamacpp"}])[0] == "openrouter"
finally: p.kill(); p.wait()
p = run("bad:free,bad:free")
try:
    r, b = call(False); assert r == "local" and b'"chat"' in b, (r, b)
    assert LAST["reason"] == "auto bad:free:429 bad:free:cooldown local", LAST
    r, b = call(True); assert r == "local" and b"[DONE]" in b   # second call hits cooldown path
    assert LAST["reason"] == "auto bad:free:cooldown bad:free:cooldown local", LAST
    r, b = call(False, "orfree/hybrid"); assert r == "local" and b'"chat"' in b, (r, b)
    assert LAST["reason"] == "hybrid bad:free:cooldown bad:free:cooldown local", LAST
finally: p.kill(); p.wait()
print("ok")
