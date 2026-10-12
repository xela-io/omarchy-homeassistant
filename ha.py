#!/usr/bin/env python3
"""Home Assistant bridge for the bar widget.

Holds one WebSocket connection to Home Assistant and speaks JSON lines:
  stdout: {"type": "status" | "layout" | "states" | "state" | "error", ...}
  stdin:  {"domain": "light", "service": "toggle", "entity_id": "...", "data": {...}}
          {"dashboard": "dashboard-infra"}

Entities come from the chosen dashboard (stdin {"dashboard": url_path}, kept
in the config file); an auto-generated dashboard falls back to grouping by
area, like Home Assistant does itself. Python stdlib only.
"""
import base64
import json
import os
import select
import socket
import ssl
import struct
import subprocess
import sys
import time
from urllib.parse import urlparse

CONFIG = os.path.expanduser("~/.config/omarchy/home-assistant.json")


DEFAULT_DASHBOARD = "lovelace"


def load_config():
    try:
        with open(CONFIG) as f:
            cfg = json.load(f)
        return cfg if isinstance(cfg, dict) else {}
    except (OSError, ValueError):
        return {}


def save_dashboard(url_path):
    cfg = load_config()
    cfg["dashboard"] = url_path
    try:
        tmp = CONFIG + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cfg, f, indent=2)
            f.write("\n")
        os.replace(tmp, CONFIG)
    except OSError:
        pass


URL = str(load_config().get("url") or "http://homeassistant.local:8123").rstrip("/")

# Attributes the widget actually reads; everything else stays out of the pipe.
ATTRS = ("friendly_name", "unit_of_measurement", "device_class", "icon",
         "brightness", "supported_color_modes", "current_temperature",
         "temperature", "min_temp", "max_temp", "target_temp_step",
         "hvac_action", "current_position", "supported_features",
         "media_title", "media_artist", "percentage")
# Order of domains inside an area in the auto layout, controls first.
DOMAIN_ORDER = ["light", "switch", "fan", "cover", "climate", "lock",
                "media_player", "input_boolean", "scene", "script", "button",
                "sensor", "binary_sensor"]
STATELESS = {"scene", "script", "button", "input_button"}
SKIP_DOMAINS = {"automation", "update", "zone", "person", "sun", "tts", "stt",
                "conversation", "event", "device_tracker", "todo", "weather",
                "image", "camera", "number", "select", "input_number",
                "input_select", "input_text", "input_datetime", "text",
                "time", "date", "datetime", "wake_word", "assist_satellite",
                "notify", "calendar", "ai_task"}


def emit(obj):
    if obj.get("type") == "status":
        obj["url"] = URL
    try:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    except BrokenPipeError:
        os._exit(0)  # the widget is gone


def token():
    try:
        out = subprocess.run(
            ["secret-tool", "lookup", "service", "home-assistant", "url", URL],
            capture_output=True, text=True, timeout=10)
        return out.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


class WebSocket:
    """Minimal RFC 6455 client: text frames, ping/pong, fragmentation."""

    def __init__(self, url):
        u = urlparse(url)
        secure = u.scheme == "https"
        port = u.port or (443 if secure else 80)
        sock = socket.create_connection((u.hostname, port), timeout=10)
        if secure:
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=u.hostname)
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((
            f"GET /api/websocket HTTP/1.1\r\nHost: {u.hostname}:{port}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("Handshake aborted")
            head += chunk
        head, self.buf = head.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise ConnectionError(head.split(b"\r\n", 1)[0].decode(errors="replace"))
        sock.settimeout(None)
        self.sock = sock
        self.fragments = []

    def fileno(self):
        return self.sock.fileno()

    def pending(self):
        return isinstance(self.sock, ssl.SSLSocket) and self.sock.pending() > 0

    def _send(self, opcode, payload):
        n = len(payload)
        header = bytes([0x80 | opcode])
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack("!H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack("!Q", n)
        mask = os.urandom(4)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def send(self, obj):
        self._send(0x1, json.dumps(obj).encode())

    def read(self):
        """Receive what is available and return the complete text messages."""
        chunk = self.sock.recv(1 << 16)
        if not chunk:
            raise ConnectionError("Connection closed")
        self.buf += chunk
        out = []
        while True:
            b = self.buf
            if len(b) < 2:
                break
            fin, opcode, n, i = b[0] & 0x80, b[0] & 0x0F, b[1] & 0x7F, 2
            if n == 126:
                if len(b) < 4:
                    break
                n, i = struct.unpack("!H", b[2:4])[0], 4
            elif n == 127:
                if len(b) < 10:
                    break
                n, i = struct.unpack("!Q", b[2:10])[0], 10
            if len(b) < i + n:
                break
            payload, self.buf = b[i:i + n], b[i + n:]
            if opcode == 0x9:
                self._send(0xA, payload)
            elif opcode == 0x8:
                raise ConnectionError("Server closed the connection")
            elif opcode in (0x0, 0x1):
                self.fragments.append(payload)
                if fin:
                    out.append(json.loads(b"".join(self.fragments)))
                    self.fragments = []
        return out

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def card_entities(card):
    """Entity ids (with optional name override) a dashboard card shows."""
    out = []
    if not isinstance(card, dict):
        return out
    if isinstance(card.get("entity"), str):
        out.append({"id": card["entity"], "name": card.get("name")})
    for e in card.get("entities") or []:
        if isinstance(e, str):
            out.append({"id": e})
        elif isinstance(e, dict) and isinstance(e.get("entity"), str):
            out.append({"id": e["entity"], "name": e.get("name")})
    for sub in card.get("cards") or []:
        out += card_entities(sub)
    if isinstance(card.get("card"), dict):  # conditional cards
        out += card_entities(card["card"])
    return out


def dashboard_layout(config):
    sections = []
    for view in config.get("views") or []:
        if view.get("subview"):
            continue
        view_title = view.get("title") or ""
        for card in view.get("cards") or []:
            sections.append({"title": card.get("title") or view_title,
                             "entities": card_entities(card)})
        for section in view.get("sections") or []:
            title, ents = section.get("title") or "", []
            for card in section.get("cards") or []:
                if card.get("type") == "heading" and not title:
                    title = card.get("heading") or ""
                ents += card_entities(card)
            sections.append({"title": title or view_title, "entities": ents})
    return sections


def area_layout(areas, devices, entities, states):
    area_names = {a["area_id"]: a["name"] for a in areas}
    device_area = {d["id"]: d.get("area_id") for d in devices}
    registry = {e["entity_id"]: e for e in entities}
    groups = {}
    for eid in states:
        domain = eid.split(".", 1)[0]
        if domain in SKIP_DOMAINS:
            continue
        # Dead entities (stale Plex clients and the like) only add noise here.
        # Scenes and buttons read "unknown" until first used, so they stay.
        state = states[eid]["state"]
        if state == "unavailable" or (state == "unknown" and domain not in STATELESS):
            continue
        reg = registry.get(eid, {})
        if reg.get("hidden_by") or reg.get("disabled_by") or reg.get("entity_category"):
            continue
        area = reg.get("area_id") or device_area.get(reg.get("device_id"))
        groups.setdefault(area_names.get(area, ""), []).append(eid)

    def rank(eid):
        d = eid.split(".", 1)[0]
        return (DOMAIN_ORDER.index(d) if d in DOMAIN_ORDER else 99, eid)

    sections = []
    for name in sorted(groups, key=lambda n: (n == "", n.lower())):
        ents = []
        for eid in sorted(groups[name], key=rank):
            friendly = states[eid]["attributes"].get("friendly_name") or eid
            # Home Assistant drops the area name from entity names in its own
            # area cards: "Kitchen Light" in Kitchen reads as "Light".
            if name and friendly.lower().startswith(name.lower() + " "):
                friendly = friendly[len(name) + 1:]
            ents.append({"id": eid, "name": friendly})
        # An empty title is the "no area" section; the widget names it.
        sections.append({"title": name, "entities": ents})
    return sections


def finish_layout(sections, states):
    """Drop unknown and duplicate entities and empty sections."""
    seen, out = set(), []
    for s in sections:
        ents = []
        for e in s["entities"]:
            if e["id"] in states and e["id"] not in seen:
                seen.add(e["id"])
                ents.append({k: v for k, v in e.items() if v})
        if ents and out and out[-1]["title"] == s["title"]:
            out[-1]["entities"] += ents  # untitled cards of one view
        elif ents:
            out.append({"title": s["title"], "entities": ents})
    return out, seen


def slim(state):
    return {"state": state["state"],
            "attributes": {k: v for k, v in state["attributes"].items() if k in ATTRS}}


class Session:
    def __init__(self, ws, tok):
        self.ws, self.token = ws, tok
        self.next_id = 1
        self.pending = {}  # id -> handler name
        self.states, self.results = {}, {}
        self.watched = set()
        self.dashboard = str(load_config().get("dashboard") or DEFAULT_DASHBOARD)

    def request_dashboard(self):
        msg = {"type": "lovelace/config"}
        if self.dashboard != DEFAULT_DASHBOARD:
            msg["url_path"] = self.dashboard
        self.request("lovelace:" + self.dashboard, msg)

    def set_dashboard(self, url_path):
        self.dashboard = str(url_path or DEFAULT_DASHBOARD)
        save_dashboard(self.dashboard)
        for k in ("lovelace", "_done"):
            self.results.pop(k, None)
        self.request_dashboard()

    def request(self, name, msg):
        msg["id"] = self.next_id
        self.pending[self.next_id] = name
        self.next_id += 1
        self.ws.send(msg)

    def handle(self, msg):
        t = msg.get("type")
        if t == "auth_required":
            self.ws.send({"type": "auth", "access_token": self.token})
        elif t == "auth_invalid":
            raise PermissionError("auth_invalid")
        elif t == "auth_ok":
            emit({"type": "status", "connected": True, "version": msg.get("ha_version")})
            self.request("states", {"type": "get_states"})
            self.request("dashboards", {"type": "lovelace/dashboards/list"})
            self.request_dashboard()
            self.request("subscribe", {"type": "subscribe_events", "event_type": "state_changed"})
        elif t == "result":
            name = self.pending.pop(msg["id"], None)
            if name == "call" and not msg.get("success"):
                emit({"type": "error", "message": (msg.get("error") or {}).get("message", "Action failed")})
            elif name == "dashboards":
                boards = [{"id": DEFAULT_DASHBOARD, "title": "Overview"}]
                for d in (msg.get("result") if msg.get("success") else None) or []:
                    if d.get("url_path") == DEFAULT_DASHBOARD:
                        boards[0]["title"] = d.get("title") or "Overview"
                    elif d.get("url_path"):
                        boards.append({"id": d["url_path"], "title": d.get("title") or d["url_path"]})
                emit({"type": "dashboards", "dashboards": boards})
            elif name == "lovelace:" + self.dashboard:
                self.results["lovelace"] = msg.get("result") if msg.get("success") else None
                self.maybe_layout()
            elif name == "states":
                # Kept current by state_changed events from here on.
                self.states = {s["entity_id"]: s for s in msg.get("result") or []}
                self.results["states"] = True
                self.maybe_layout()
            elif name in ("areas", "devices", "entities"):
                self.results[name] = msg.get("result") if msg.get("success") else None
                self.maybe_layout()
        elif t == "event":
            data = msg["event"].get("data") or {}
            eid, new = data.get("entity_id"), data.get("new_state")
            if new:
                self.states[eid] = new
            if eid in self.watched:
                emit({"type": "state", "entity_id": eid, **(slim(new) if new else {"state": "unavailable", "attributes": {}})})

    def maybe_layout(self):
        r = self.results
        if "states" not in r or "lovelace" not in r:
            return
        if r.get("_done"):
            return
        cfg = r["lovelace"]
        if isinstance(cfg, dict) and cfg.get("views"):
            sections = dashboard_layout(cfg)
        else:
            # No stored dashboard (auto-generated or a strategy): group by area.
            if "areas" not in r:
                self.request("areas", {"type": "config/area_registry/list"})
                self.request("devices", {"type": "config/device_registry/list"})
                self.request("entities", {"type": "config/entity_registry/list"})
                r["areas"] = Ellipsis
                return
            if any(r.get(k) is Ellipsis or k not in r for k in ("areas", "devices", "entities")):
                return
            sections = area_layout(r["areas"] or [], r["devices"] or [], r["entities"] or [], self.states)
        r["_done"] = True
        sections, self.watched = finish_layout(sections, self.states)
        emit({"type": "layout", "sections": sections, "dashboard": self.dashboard,
              "source": "dashboard" if isinstance(cfg, dict) and cfg.get("views") else "areas"})
        emit({"type": "states", "states": {e: slim(self.states[e]) for e in self.watched}})

    def command(self, line):
        try:
            c = json.loads(line)
        except ValueError:
            return
        if "dashboard" in c:
            self.set_dashboard(c["dashboard"])
            return
        self.request("call", {"type": "call_service", "domain": c["domain"], "service": c["service"],
                              "service_data": c.get("data") or {}, "target": {"entity_id": c["entity_id"]}})


def run_once(stdin_buf):
    tok = token()
    if not tok:
        raise PermissionError("no_token")
    ws = WebSocket(URL)
    session = Session(ws, tok)
    try:
        while True:
            ready = [ws] if ws.pending() else select.select([ws, sys.stdin], [], [], 60)[0]
            if not ready:
                session.request("ping", {"type": "ping"})
                continue
            if sys.stdin in ready:
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    sys.exit(0)  # widget went away
                stdin_buf[0] += data
                *lines, stdin_buf[0] = stdin_buf[0].split(b"\n")
                for line in lines:
                    if line.strip():
                        session.command(line)
            if ws in ready:
                for msg in ws.read():
                    session.handle(msg)
    finally:
        ws.close()


def main():
    backoff, stdin_buf = 2, [b""]
    while True:
        started = time.time()
        try:
            run_once(stdin_buf)
        except PermissionError as e:
            emit({"type": "status", "connected": False, "auth": str(e)})
            backoff = 30
        except (OSError, ConnectionError, ValueError) as e:
            if time.time() - started > 60:
                backoff = 2  # a long-lived connection dropped: retry quickly
            emit({"type": "status", "connected": False, "error": str(e) or e.__class__.__name__})
        # Drain stdin while waiting so an exiting widget still stops us.
        deadline = time.time() + backoff
        while (left := deadline - time.time()) > 0:
            if select.select([sys.stdin], [], [], left)[0] and not os.read(sys.stdin.fileno(), 65536):
                sys.exit(0)
        backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
