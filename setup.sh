#!/bin/bash
# Jellyfin Menu Bar App – Setup (nutzt native WireGuard.app via scutil --nc)
set -eo pipefail

VERSION="1.2.0"
# GitHub-Repo für Update-Check
REPO="Hamzelot/jelly-macos"
REPO_RAW="https://raw.githubusercontent.com/${REPO}/main"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}✓${NC} $*"; }
info()  { echo -e "${BLUE}→${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.setup_state"
APP_PATH="/Applications/Jellyfin.app"
WG_APP="/Applications/WireGuard.app"
APP_PY="${SCRIPT_DIR}/_jellyfin_app_build.py"
ICON_PY="${SCRIPT_DIR}/_make_icon.py"
ICONSET="/tmp/jellyfin-icon.iconset"
ICON_FILE="/tmp/jellyfin.icns"
PYI_LOG=""

# ── Update-Check (GitHub) ──────────────────────────────────────────────────────
# Vergleicht VERSION mit /VERSION aus dem Repo. Bei Treffer optionaler Self-Update.
check_for_update() {
  [[ "$REPO" == "YOUR_USER/YOUR_REPO" ]] && return 0     # nicht konfiguriert
  [[ "${1:-}" == "--no-update" ]]       && return 0      # explizit übersprungen
  command -v curl &>/dev/null           || return 0

  local latest
  latest=$(curl -fsSL --max-time 5 "${REPO_RAW}/VERSION" 2>/dev/null | tr -d '[:space:]' || true)
  [[ -z "$latest" || "$latest" == "$VERSION" ]] && return 0

  echo ""
  echo -e "  ${YELLOW}📦  Update verfügbar: ${VERSION} → ${latest}${NC}"
  read -rp "  Jetzt updaten? [J/n] " -n 1 REPLY; echo ""
  [[ ${REPLY:-J} =~ ^[Nn]$ ]] && return 0

  local tmp; tmp=$(mktemp)
  if curl -fsSL --max-time 30 -o "$tmp" "${REPO_RAW}/setup.sh"; then
    # Einfache Sanity-Prüfung: ist es wirklich ein Bash-Script?
    if head -1 "$tmp" | grep -q '^#!/bin/bash'; then
      cp "$tmp" "${BASH_SOURCE[0]}"
      chmod +x "${BASH_SOURCE[0]}"
      rm -f "$tmp"
      log "Update auf ${latest} installiert. Starte neu..."
      exec "${BASH_SOURCE[0]}" --no-update "$@"
    fi
    rm -f "$tmp"
    warn "Downloadete Datei sieht nicht wie ein Bash-Script aus — abgebrochen."
  else
    rm -f "$tmp"
    warn "Update-Download fehlgeschlagen, fahre mit aktueller Version fort."
  fi
}

# ── Cleanup bei Abbruch oder Fehler ────────────────────────────────────────────
_cleanup() {
  rm -f "$APP_PY" "$ICON_PY" "$ICON_FILE" 2>/dev/null || true
  rm -rf "$ICONSET" /tmp/jellyfin-dist /tmp/jellyfin-build /tmp/jellyfin-spec 2>/dev/null || true
  [[ -n "$PYI_LOG" ]] && rm -f "$PYI_LOG" 2>/dev/null || true
}
trap _cleanup EXIT

# ── Update-Check (vor allem anderen, nur bei normalem Setup) ───────────────────
if [[ -z "${1:-}" || "${1:-}" == "--no-update" ]]; then
  check_for_update "$@"
fi

# ── Entfernen ──────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--remove" ]]; then
  echo ""
  echo "  🗑️  Jellyfin entfernen"
  echo ""
  read -rp "  Wirklich entfernen? [j/N] " -n 1 REPLY; echo ""
  [[ ! $REPLY =~ ^[Jj]$ ]] && exit 0

  killall Jellyfin 2>/dev/null || true
  sleep 1
  rm -rf "$APP_PATH"
  rm -rf "${SCRIPT_DIR}/.venv"
  rm -f  "$STATE_FILE"

  # Altlasten aus früherer wg-quick-Version aufräumen (falls vorhanden)
  sudo rm -f /etc/sudoers.d/jellyfin-wg 2>/dev/null || true
  if command -v brew &>/dev/null; then
    BREW_PFX=$(brew --prefix 2>/dev/null)
    sudo rm -f "${BREW_PFX}/etc/wireguard/wg0.conf" 2>/dev/null || true
  fi

  log "Entfernt! (WireGuard.app + VPN-Config bleiben — manuell in WireGuard.app entfernen falls gewünscht)"
  exit 0
fi

# ── IP zurücksetzen ────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--reset-ip" ]]; then
  sed -i '' '/^JELLYFIN_IP=/d' "$STATE_FILE" 2>/dev/null || true
  log "Jellyfin-IP zurückgesetzt. Setup erneut starten."
  exit 0
fi

# ── Intro ──────────────────────────────────────────────────────────────────────
echo ""
echo "  🎬  Jellyfin Setup"
echo "  ─────────────────"
echo ""

# ── WireGuard.app prüfen ───────────────────────────────────────────────────────
info "Prüfe WireGuard.app..."
if [[ ! -d "$WG_APP" ]]; then
  echo ""
  echo -e "${YELLOW}  WireGuard.app fehlt!${NC}"
  echo ""
  echo "  Bitte zuerst aus dem App Store installieren (gratis):"
  echo "  → https://apps.apple.com/app/wireguard/id1451685025"
  echo ""
  read -rp "  App Store jetzt öffnen? [J/n] " -n 1 REPLY; echo ""
  if [[ ! ${REPLY:-J} =~ ^[Nn]$ ]]; then
    open "macappstore://apps.apple.com/app/wireguard/id1451685025"
  fi
  echo ""
  echo "  Nach der Installation: setup.sh erneut starten."
  exit 1
fi
log "WireGuard.app gefunden"

# ── WireGuard .conf finden ─────────────────────────────────────────────────────
info "Suche WireGuard .conf..."
CONF=""
for _f in "$SCRIPT_DIR"/*.conf; do
  [[ -f "$_f" ]] && CONF="$_f" && break
done
[[ -z "$CONF" ]] && error "Keine .conf-Datei gefunden! In $SCRIPT_DIR ablegen."
log "Gefunden: $(basename "$CONF")"

# ── Jellyfin IP ────────────────────────────────────────────────────────────────
JELLYFIN_IP=$(grep "^JELLYFIN_IP=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
if [[ -z "$JELLYFIN_IP" ]]; then
  echo ""
  echo "  Jellyfin-Server IP eingeben (z.B. 192.168.178.2):"
  read -rp "  IP: " JELLYFIN_IP
  [[ -z "$JELLYFIN_IP" ]] && error "Keine IP angegeben!"
  if ! [[ "$JELLYFIN_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    error "Ungültiges IP-Format: $JELLYFIN_IP"
  fi
  echo "JELLYFIN_IP=${JELLYFIN_IP}" >> "$STATE_FILE"
fi
JELLYFIN_URL="http://${JELLYFIN_IP}:8096"
log "Jellyfin: $JELLYFIN_URL"

# ── VPN in WireGuard.app importieren/erkennen ──────────────────────────────────
list_wg_vpns() {
  # Extrahiert alle WireGuard-VPN-Namen aus scutil --nc list
  scutil --nc list 2>/dev/null | awk -F '"' '/[Ww]ire[Gg]uard/ { print $2 }'
}

read_vpns_into_array() {
  # Füllt globales VPNS-Array (bash 3.2 kompatibel, kein mapfile)
  VPNS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && VPNS+=("$line")
  done < <(list_wg_vpns)
}

info "Suche WireGuard-VPN in macOS..."
read_vpns_into_array

if [[ ${#VPNS[@]} -eq 0 ]]; then
  echo ""
  echo "  Keine WireGuard-VPN gefunden. Bitte jetzt importieren:"
  echo ""
  echo "  1. WireGuard.app öffnet sich gleich"
  echo "  2. '$(basename "$CONF")' per Drag & Drop in WireGuard.app ziehen"
  echo "     (oder: Add Tunnel → Import tunnel(s) from file)"
  echo "  3. 'Allow' in den Systemeinstellungen bestätigen"
  echo ""
  read -rp "  [Enter] drücken um WireGuard.app zu öffnen..." _
  open -a WireGuard "$CONF" 2>/dev/null || open -a WireGuard
  echo ""
  read -rp "  [Enter] drücken wenn der Import abgeschlossen ist..." _
  read_vpns_into_array
fi

[[ ${#VPNS[@]} -eq 0 ]] && error "Keine WireGuard-VPN in macOS gefunden. Import in WireGuard.app fehlgeschlagen?"

# Bei mehreren VPNs User wählen lassen
if [[ ${#VPNS[@]} -gt 1 ]]; then
  echo ""
  echo "  Mehrere WireGuard-VPNs gefunden:"
  for i in "${!VPNS[@]}"; do
    echo "    [$((i+1))] ${VPNS[$i]}"
  done
  read -rp "  Welche soll gesteuert werden? [1] " CHOICE
  CHOICE=${CHOICE:-1}
  VPN_NAME="${VPNS[$((CHOICE-1))]:-}"
  [[ -z "$VPN_NAME" ]] && error "Ungültige Auswahl!"
else
  VPN_NAME="${VPNS[0]}"
fi

# Sanity-Check: keine Anführungszeichen im Namen (würden sed/Python brechen)
if [[ "$VPN_NAME" == *'"'* ]]; then
  error "VPN-Name enthält \" — bitte umbenennen in WireGuard.app."
fi
log "VPN: $VPN_NAME"

# ── Homebrew (nur für Python) ──────────────────────────────────────────────────
info "Prüfe Homebrew..."
if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
  eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
  eval "$(/usr/local/bin/brew shellenv)"    2>/dev/null || true
fi
command -v brew &>/dev/null || error "Homebrew konnte nicht installiert werden!"
BREW_PREFIX=$(brew --prefix)
log "Homebrew OK (${BREW_PREFIX})"

info "Installiere Python..."
brew install python3 2>/dev/null || true
log "Python OK"

# ── Python venv ────────────────────────────────────────────────────────────────
info "Python-Umgebung..."
PYTHON="${BREW_PREFIX}/bin/python3"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3 2>/dev/null)" || error "Python3 nicht gefunden!"
[[ -d "${SCRIPT_DIR}/.venv" ]] || "$PYTHON" -m venv "${SCRIPT_DIR}/.venv"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/.venv/bin/activate"
PYTHON="python3"
pip install --quiet rumps pyinstaller pillow || error "pip install fehlgeschlagen!"
log "Python-Umgebung OK"

# ── App-Code schreiben ─────────────────────────────────────────────────────────
info "Baue App..."
cat > "$APP_PY" << 'PYEOF'
#!/usr/bin/env python3
"""Jellyfin Menubar — triggert macOS-native WireGuard.app via scutil --nc."""
import rumps, subprocess, threading, time, socket, signal, atexit, sys
import urllib.request
from AppKit import NSWorkspace

VERSION      = "VERSION_PLACEHOLDER"
REPO         = "REPO_PLACEHOLDER"                # YOUR_USER/YOUR_REPO oder leer
VPN_NAME     = "VPN_NAME_PLACEHOLDER"
JELLYFIN_IP  = "JELLYFIN_IP_PLACEHOLDER"
JELLYFIN_URL = f"http://{JELLYFIN_IP}:8096"
REPO_URL     = f"https://github.com/{REPO}" if REPO and REPO != "YOUR_USER/YOUR_REPO" else ""

_exiting = False

# ── VPN-Steuerung (scutil --nc) ────────────────────────────────────────────────

def vpn_exists():
    """Prüft ob die VPN in macOS registriert ist (z.B. in WireGuard.app importiert)."""
    try:
        r = subprocess.run(["scutil", "--nc", "list"],
                           capture_output=True, timeout=3, text=True)
        return r.returncode == 0 and f'"{VPN_NAME}"' in r.stdout
    except Exception:
        return False

def vpn_status():
    """Liefert: 'Connected', 'Connecting', 'Disconnecting', 'Disconnected' oder None."""
    try:
        r = subprocess.run(
            ["scutil", "--nc", "status", VPN_NAME],
            capture_output=True, timeout=3, text=True
        )
        if r.returncode != 0:
            return None
        for line in r.stdout.splitlines():
            line = line.strip()
            if line:
                return line
        return None
    except Exception:
        return None

def is_connected():
    return vpn_status() == "Connected"

def vpn_start():
    """Startet die VPN. Gibt (ok, stderr) zurück."""
    try:
        r = subprocess.run(["scutil", "--nc", "start", VPN_NAME],
                           capture_output=True, timeout=5, text=True)
        return r.returncode == 0, (r.stderr or "").strip()
    except subprocess.TimeoutExpired:
        return False, "scutil hat beim Starten nicht reagiert"
    except Exception as e:
        return False, str(e)

def vpn_stop():
    try:
        subprocess.run(["scutil", "--nc", "stop", VPN_NAME],
                       capture_output=True, timeout=5)
    except Exception:
        pass

def wait_for_status(target, max_seconds, on_change=None):
    """Wartet bis scutil den Ziel-Status meldet. on_change(status) wird bei
    jedem Statuswechsel aufgerufen → live-Update in der UI."""
    deadline = time.monotonic() + max_seconds
    last = None
    while time.monotonic() < deadline:
        status = vpn_status()
        if status != last:
            last = status
            if on_change:
                try: on_change(status)
                except Exception: pass
        if status == target:
            return True
        time.sleep(0.5)
    return False

def fetch_latest_version():
    """Holt die aktuelle Version von GitHub. None bei Fehler/nicht konfiguriert."""
    if not REPO or REPO == "YOUR_USER/YOUR_REPO":
        return None
    try:
        url = f"https://raw.githubusercontent.com/{REPO}/main/VERSION"
        req = urllib.request.Request(url, headers={"User-Agent": "Jellyfin-Menubar"})
        with urllib.request.urlopen(req, timeout=5) as r:
            latest = r.read().decode("utf-8", errors="replace").strip()
        # Sanity: nur Zahlen und Punkte zulassen
        if latest and all(c in "0123456789." for c in latest):
            return latest
    except Exception:
        pass
    return None

def wait_reachable(max_seconds=10):
    """TCP-Connect auf Jellyfin — bestätigt dass Traffic wirklich routet."""
    deadline = time.monotonic() + max_seconds
    while time.monotonic() < deadline:
        s = None
        try:
            s = socket.create_connection((JELLYFIN_IP, 8096), timeout=1)
            return True
        except OSError:
            time.sleep(0.5)
        finally:
            if s is not None:
                try: s.close()
                except Exception: pass
    return False

# ── Shutdown ───────────────────────────────────────────────────────────────────

def _cleanup():
    if _exiting:
        return
    try:
        if is_connected():
            vpn_stop()
    except Exception:
        pass

def _signal_handler(*_):
    sys.exit(0)

atexit.register(_cleanup)
signal.signal(signal.SIGTERM, _signal_handler)
signal.signal(signal.SIGINT,  _signal_handler)

# ── App ────────────────────────────────────────────────────────────────────────

class JellyfinApp(rumps.App):
    def __init__(self):
        super().__init__("Jellyfin", title="○", quit_button=None)
        self.connected  = False
        self._busy      = False
        self.last_error = None
        self._was_connected_before_sleep = False

        self.status_item = rumps.MenuItem("○ Nicht verbunden")
        self.error_item  = rumps.MenuItem("")      # sichtbar nur bei Fehler
        self.toggle_item = rumps.MenuItem("Verbinden",       callback=self._toggle)
        self.open_item   = rumps.MenuItem("Jellyfin öffnen", callback=self._open)
        self.quit_item   = rumps.MenuItem("Beenden",         callback=self._quit)

        # Info-Items (keine callback → disabled/grau)
        self.vpn_info_item  = rumps.MenuItem(f"VPN: {VPN_NAME}")
        self.ip_info_item   = rumps.MenuItem(f"Server: {JELLYFIN_IP}")
        self.version_item   = rumps.MenuItem(f"Version {VERSION}")
        self.update_item    = rumps.MenuItem("", callback=self._open_update_page)

        self.menu = [
            self.status_item,
            self.error_item,
            None,
            self.toggle_item,
            self.open_item,
            None,
            self.vpn_info_item,
            self.ip_info_item,
            None,
            self.quit_item,
            None,
            self.version_item,
            self.update_item,
        ]
        # Update-/Error-Items initial ausblenden
        self.error_item.hidden  = True
        self.update_item.hidden = True

        self._poll_lock = threading.Lock()
        self._timer = rumps.Timer(self._poll_status, 10)
        self._timer.start()
        threading.Thread(target=self._initial_check, daemon=True).start()
        threading.Thread(target=self._check_update, daemon=True).start()

        # Sleep/Wake-Observer registrieren (macOS-native via NSWorkspace)
        self._register_sleep_observers()

    def _register_sleep_observers(self):
        """Registriert Handler für System-Sleep und -Wake.
        WillSleep → VPN trennen, DidWake → VPN reconnecten (wenn vorher verbunden)."""
        nc = NSWorkspace.sharedWorkspace().notificationCenter()
        nc.addObserver_selector_name_object_(
            self, b"_willSleep:", "NSWorkspaceWillSleepNotification", None)
        nc.addObserver_selector_name_object_(
            self, b"_didWake:",   "NSWorkspaceDidWakeNotification",   None)

    # PyObjc-Selektoren (Unterstrich-Suffix pro Obj-C-Konvention)
    def _willSleep_(self, notification):
        """Wird von macOS direkt vor System-Sleep aufgerufen (blocking)."""
        if self.connected and not self._exiting_flag():
            self._was_connected_before_sleep = True
            # Synchron trennen — wir haben nur wenige Sekunden vor dem Sleep
            vpn_stop()

    def _didWake_(self, notification):
        """Wird von macOS nach System-Wake aufgerufen."""
        if self._was_connected_before_sleep and not self._busy:
            self._was_connected_before_sleep = False
            self._busy = True
            threading.Thread(target=self._wake_reconnect, daemon=True).start()

    def _wake_reconnect(self):
        """Reconnect nach Wake — gibt dem Netzwerk kurz Zeit zu stabilisieren."""
        time.sleep(3)
        try:
            self._do_connect()        # managed _busy selbst via finally
        except Exception:
            self._busy = False

    def _exiting_flag(self):
        return _exiting

    def _check_update(self):
        """Fragt GitHub nach neuer Version. Blendet Menü-Item ein wenn Update da."""
        latest = fetch_latest_version()
        if latest and latest != VERSION:
            self.update_item.title  = f"⬆ Update verfügbar: {latest}"
            self.update_item.hidden = False

    def _open_update_page(self, _):
        if REPO_URL:
            subprocess.Popen(["open", REPO_URL])

    # ── Status ─────────────────────────────────────────────────────────────────

    def _initial_check(self):
        self.connected = is_connected()
        self._refresh_ui()

    def _poll_status(self, _):
        if self._busy: return
        if not self._poll_lock.acquire(blocking=False): return
        try:
            connected = is_connected()
            if connected != self.connected:
                self.connected = connected
                # Bei erfolgreicher Verbindung letzten Fehler löschen
                if connected:
                    self._clear_error()
                self._refresh_ui()
        finally:
            self._poll_lock.release()

    def _refresh_ui(self):
        if self.connected:
            self.title             = "●"
            self.status_item.title = "● Verbunden"
            self.toggle_item.title = "Trennen"
        else:
            self.title             = "○"
            self.status_item.title = "○ Nicht verbunden"
            self.toggle_item.title = "Verbinden"

    # ── Fehler-Handling ────────────────────────────────────────────────────────

    def _set_error(self, title, detail):
        """Zeigt Fehler im Menü + als Notification."""
        self.last_error = f"{title}: {detail}" if detail else title
        self.error_item.title  = f"⚠ {title}"
        self.error_item.hidden = False
        try:
            rumps.notification("Jellyfin", title, detail or "")
        except Exception:
            pass

    def _clear_error(self):
        self.last_error        = None
        self.error_item.title  = ""
        self.error_item.hidden = True

    # ── Aktionen ───────────────────────────────────────────────────────────────

    def _toggle(self, _):
        if self._busy: return
        self._busy = True
        target = self._do_disconnect if self.connected else self._do_connect
        threading.Thread(target=target, daemon=True).start()

    def _do_connect(self):
        try:
            self.title             = "…"
            self.status_item.title = "… Verbinde"
            self._clear_error()

            # 1. VPN überhaupt in macOS vorhanden?
            if not vpn_exists():
                self._set_error(
                    "VPN nicht gefunden",
                    f"'{VPN_NAME}' fehlt in macOS. "
                    f"In WireGuard.app importieren und setup.sh erneut ausführen."
                )
                self._refresh_ui()
                return

            # 2. Start-Befehl senden
            ok, err = vpn_start()
            if not ok:
                self._set_error("VPN-Start fehlgeschlagen",
                                err or "scutil lieferte Fehler zurück")
                self._refresh_ui()
                return

            # 3. Auf "Connected" warten, mit Live-Status-Update
            def _on_change(status):
                label = {"Connecting":    "… Verbinde",
                         "Disconnecting": "… Trenne",
                         "Disconnected":  "○ Nicht verbunden",
                         "Connected":     "● Verbunden"}.get(status, f"… {status}")
                self.status_item.title = label

            if not wait_for_status("Connected", max_seconds=20, on_change=_on_change):
                current = vpn_status() or "unbekannt"
                self.connected = is_connected()
                self._refresh_ui()
                self._set_error(
                    "VPN-Verbindung fehlgeschlagen",
                    f"Status nach 20s: {current}. "
                    f"Internet/Server-Endpoint prüfen."
                )
                return

            # 4. Jellyfin-Erreichbarkeit prüfen
            if wait_reachable():
                self.connected = True
                self._refresh_ui()
                rumps.notification("Jellyfin", "Verbunden", "VPN ist aktiv")
                subprocess.Popen(["open", JELLYFIN_URL])
            else:
                # VPN ist connected aber Jellyfin antwortet nicht
                self.connected = is_connected()
                self._refresh_ui()
                self._set_error(
                    "Jellyfin nicht erreichbar",
                    f"VPN aktiv, aber {JELLYFIN_IP}:8096 antwortet nicht. "
                    f"IP oder AllowedIPs in der Tunnel-Config prüfen."
                )
        finally:
            self._busy = False

    def _do_disconnect(self):
        try:
            self.title             = "…"
            self.status_item.title = "… Trenne"
            vpn_stop()

            def _on_change(status):
                label = {"Connecting":    "… Verbinde",
                         "Disconnecting": "… Trenne",
                         "Disconnected":  "○ Nicht verbunden",
                         "Connected":     "● Verbunden"}.get(status, f"… {status}")
                self.status_item.title = label

            wait_for_status("Disconnected", max_seconds=10, on_change=_on_change)
            self.connected = is_connected()
            self._refresh_ui()
            if not self.connected:
                self._clear_error()
                rumps.notification("Jellyfin", "Getrennt", "VPN beendet")
            else:
                current = vpn_status() or "unbekannt"
                self._set_error("VPN trennen fehlgeschlagen",
                                f"Status: {current}")
        finally:
            self._busy = False

    def _open(self, _):
        if self._busy: return
        if self.connected:
            subprocess.Popen(["open", JELLYFIN_URL])
        else:
            self._busy = True
            threading.Thread(target=self._do_connect, daemon=True).start()

    def _quit(self, _):
        global _exiting
        _exiting = True
        self._timer.stop()
        self.title = "…"
        t = threading.Thread(target=lambda: (vpn_stop(),
                             wait_for_status("Disconnected", 8)), daemon=True)
        t.start()
        t.join(timeout=10)
        rumps.quit_application()

if __name__ == "__main__":
    JellyfinApp().run()
PYEOF

# Platzhalter ersetzen (VPN-Name kann Leerzeichen haben → "|" als sed-Trenner)
sed -i '' \
  -e "s|VPN_NAME_PLACEHOLDER|${VPN_NAME}|g"       \
  -e "s|JELLYFIN_IP_PLACEHOLDER|${JELLYFIN_IP}|g" \
  -e "s|VERSION_PLACEHOLDER|${VERSION}|g"         \
  -e "s|REPO_PLACEHOLDER|${REPO}|g"               \
  "$APP_PY"

# ── Icon ───────────────────────────────────────────────────────────────────────
info "Erstelle Icon..."
cat > "$ICON_PY" << 'ICONEOF'
from PIL import Image, ImageDraw
import sys, os

def make_icon(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d   = ImageDraw.Draw(img)
    r   = size // 5
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=(0x00, 0xA4, 0xDC, 255))
    m   = size // 4
    d.polygon([(m, m), (m, size - m), (size - m, size // 2)], fill=(255, 255, 255, 240))
    return img

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for base, retina in [(16,0),(16,1),(32,0),(32,1),(128,0),(128,1),
                     (256,0),(256,1),(512,0),(512,1)]:
    px     = base * 2 if retina else base
    suffix = "@2x" if retina else ""
    make_icon(px).save(f"{out}/icon_{base}x{base}{suffix}.png")
ICONEOF

mkdir -p "$ICONSET"
$PYTHON "$ICON_PY" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICON_FILE"
log "Icon OK"

# ── PyInstaller ────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"
PYI_LOG=$(mktemp)
printf "  Kompiliere"
$PYTHON -m PyInstaller \
  --onedir --windowed --noconfirm \
  --name "Jellyfin" \
  --osx-bundle-identifier "de.jellyfin.menubar" \
  --icon "$ICON_FILE" \
  "$APP_PY" \
  --distpath /tmp/jellyfin-dist \
  --workpath /tmp/jellyfin-build \
  --specpath /tmp/jellyfin-spec >"$PYI_LOG" 2>&1 &
PYI_PID=$!

while kill -0 "$PYI_PID" 2>/dev/null; do printf "."; sleep 2; done
echo ""

if ! wait "$PYI_PID"; then
  echo ""
  echo -e "${RED}  PyInstaller fehlgeschlagen!${NC}"
  echo ""
  tail -30 "$PYI_LOG"
  error "App konnte nicht gebaut werden."
fi

[[ -d /tmp/jellyfin-dist/Jellyfin.app ]] || error "PyInstaller-Output fehlt!"
[[ -d "$APP_PATH" ]] && rm -rf "$APP_PATH"
cp -r /tmp/jellyfin-dist/Jellyfin.app "$APP_PATH"
log "App installiert → $APP_PATH"

# ── Fertig ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}  ✓ Installation abgeschlossen!${NC}"
echo ""
echo "  Menüleiste:  ○ = Getrennt    ● = Verbunden    … = Aktiv"
echo "  VPN:         $VPN_NAME (via WireGuard.app)"
echo "  Jellyfin:    $JELLYFIN_URL"
echo ""
echo "  Optionen:"
echo "    bash setup.sh --remove    App entfernen"
echo "    bash setup.sh --reset-ip  Jellyfin-IP ändern"
echo ""

read -rp "  App jetzt starten? [J/n] " -n 1 REPLY; echo ""
[[ ! ${REPLY:-J} =~ ^[Nn]$ ]] && open "$APP_PATH"
