#!/usr/bin/env python3
"""
zen_auto.py - vigia de cota do OpenCode para Linux (rotacao infinita).

Le o log em tempo real (~/.local/share/opencode/log/opencode.log), detecta o
erro de cota ("Free usage limit reached" / "FreeTierError"), gira o egress
(zen_rotate.py), testa a cota com um probe real e retoma a sessao ativa que o
operador esta usando -- sem trocar de sessao.

  zen_auto.py watch          vigia em primeiro plano
  zen_auto.py once           uma checagem pontual (sem seguir o log)
  zen_auto.py rotate         gira o egress agora e testa a cota
  zen_auto.py resume [id]    manda "continue" numa sessao (default: a ativa)
  zen_auto.py status         estado atual (lock, ultima acao, sessao ativa)
  zen_auto.py stop           marca parada graciosa (remove lock)

Env:
  ZEN_MODEL_FREE   modelo free do provider opencode (default opencode/deepseek-v4.1-flash-free)
  ZEN_ROTATE       warp|none  (zen_rotate.py usa Cloudflare WARP)
  ZEN_MAXTRIES     tentativas de rotacao por evento (default 5)
  ZEN_COOLDOWN     segundos entre eventos (default 20)
  OPENCODE_BIN     binario do opencode (default "opencode")
  OPENCODE_DB      caminho do opencode.db (default ~/.local/share/opencode/opencode.db)
  OPENCODE_LOG     caminho do opencode.log (default ~/.local/share/opencode/log/opencode.log)
"""
from __future__ import annotations
import json, os, re, shutil, sqlite3, subprocess, sys, time
from pathlib import Path

HOME = Path(os.path.expanduser("~"))
STATE_DIR = HOME / ".local/state/zen-opencode"
STATE_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE = STATE_DIR / "zen_auto.log"
LOCK_FILE = STATE_DIR / "zen_auto.lock"


def lock_stale() -> bool:
    """Lock com PID morto = preso: remove e devolve True (bug classico do vigia)."""
    if not LOCK_FILE.exists():
        return False
    try:
        pid = int(LOCK_FILE.read_text().strip() or "0")
        if pid <= 0:
            LOCK_FILE.unlink()
            return True
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            LOCK_FILE.unlink()
            return True
        except PermissionError:
            return False
        return False
    except Exception:
        try:
            LOCK_FILE.unlink()
        except Exception:
            pass
        return True
STATE_FILE = STATE_DIR / "zen_auto.state.json"
NOTICE_FILE = STATE_DIR / "zen_auto.notice.txt"

HERE = Path(__file__).resolve().parent
ROTATE = HERE / "zen_rotate.py"

OPENCODE_BIN = os.environ.get("OPENCODE_BIN", "opencode")
DB = Path(os.environ.get("OPENCODE_DB", HOME / ".local/share/opencode/opencode.db"))
LOG = Path(os.environ.get("OPENCODE_LOG", HOME / ".local/share/opencode/log/opencode.log"))
MODEL_FREE = os.environ.get("ZEN_MODEL_FREE", "opencode/deepseek-v4.1-flash-free")
MAXTRIES = int(os.environ.get("ZEN_MAXTRIES", "5"))
COOLDOWN = int(os.environ.get("ZEN_COOLDOWN", "20"))

LIMIT_PAT = re.compile(
    r'error\.error="[^"]*(Free usage limit reached|Free usage exceeded|FreeTierError)'
    r'|Free usage limit reached\. Free models work in OpenCode',
    re.IGNORECASE)
# erros que NAO sao cota: nao girar o IP, apenas esperar e tentar de novo
TRANSIENT_PAT = re.compile(
    r'peak demand|socket (connection )?was closed|Cannot connect to API|'
    r'ECONNRESET|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|fetch failed|502|503|504|'
    r'overloaded|rate.?limit',
    re.IGNORECASE)
SID_PAT = re.compile(r"session\.id=(ses_[A-Za-z0-9]+)")



def block_of(ipaddr: str) -> str:
    """/64 de um IPv6 (ou 'v4:'+ip se for IPv4)."""
    ipaddr = (ipaddr or "").strip()
    if not ipaddr:
        return ""
    if ":" not in ipaddr:
        return "v4:" + ipaddr
    # comprime o /64: pega os 4 primeiros grupos e normaliza
    m = re.match(r"([0-9a-fA-F]{1,4}):([0-9a-fA-F]{1,4}):([0-9a-fA-F]{1,4}):([0-9a-fA-F]{1,4})", ipaddr)
    if not m:
        return ipaddr
    g = [str(int(x, 16)) for x in m.groups()]
    return ":".join(g) + "::"


def load_spent() -> dict:
    try:
        return json.loads((STATE_DIR / "spent.json").read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_spent(spent: dict):
    try:
        (STATE_DIR / "spent.json").write_text(json.dumps(spent, indent=1), encoding="utf-8")
    except Exception:
        pass


def spent_today() -> set:
    spent = load_spent()
    # cota do opencode reseta a 00:00 UTC -> ledger precisa ser por dia UTC
    return set(spent.get(time.strftime("%Y-%m-%d", time.gmtime()), []))


def mark_spent(blk: str):
    spent = load_spent()
    day = time.strftime("%Y-%m-%d", time.gmtime())
    lst = spent.setdefault(day, [])
    if blk and blk not in lst:
        lst.append(blk)
    save_spent(spent)


def egress_block() -> str:
    """Pega o /64 de saida atual do SOCKS do WARP (sem gastar cota)."""
    try:
        r = subprocess.run(
            ["curl", "-s", "--max-time", "12", "--socks5-hostname", "127.0.0.1:40000",
             "https://api64.ipify.org"],
            capture_output=True, text=True, timeout=15)
        return block_of((r.stdout or "").strip())
    except Exception:
        return ""

def limit_session(buf: str) -> str | None:
    """Extrai o session.id da linha de erro de cota (o que realmente estourou)."""
    hits = SID_PAT.findall(buf or "")
    return hits[-1] if hits else None


def log(msg: str):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n"
    try:
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass
    sys.stderr.write(line)


def read_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}


def write_state(**kw):
    st = read_state()
    st.update(kw)
    STATE_FILE.write_text(json.dumps(st, indent=2), encoding="utf-8")


def run(cmd, env=None, timeout=180):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        return subprocess.CompletedProcess(cmd, 124, e.stdout or "", "timeout")


def rotate() -> str:
    """Roda zen_rotate.py e devolve a URL de proxy escolhida (ou 'direct')."""
    r = run([sys.executable, str(ROTATE)], timeout=60)
    proxy = (r.stdout or "direct").strip().splitlines()[-1] if r.stdout.strip() else "direct"
    log(f"rotate -> {proxy} (rc={r.returncode})")
    return proxy


def proxy_env(proxy: str) -> dict:
    env = os.environ.copy()
    if proxy and proxy != "direct" and not proxy.startswith("socks"):
        env["HTTPS_PROXY"] = proxy
        env["HTTP_PROXY"] = proxy
        env["https_proxy"] = proxy
        env["http_proxy"] = proxy
        env["NO_PROXY"] = "localhost,127.0.0.1,::1,opencode.ai"
    elif proxy.startswith("socks"):
        # socks precisa da ponte zen_bridge (ouvindo em 127.0.0.1:8899)
        env["HTTPS_PROXY"] = "http://127.0.0.1:8899"
        env["HTTP_PROXY"] = "http://127.0.0.1:8899"
        env["https_proxy"] = "http://127.0.0.1:8899"
        env["http_proxy"] = "http://127.0.0.1:8899"
        env["NO_PROXY"] = "localhost,127.0.0.1,::1"
    return env


def active_session() -> str | None:
    """Sessao mais recente do provider opencode, ignorando probes zen."""
    try:
        con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
        cur = con.execute(
            "SELECT id, model FROM session "
            "WHERE model LIKE '%\"providerID\":\"opencode\"%' "
            "AND id NOT IN (SELECT id FROM session WHERE title LIKE '%zen-probe%') "
            "ORDER BY time_updated DESC LIMIT 25"
        )
        for sid, model in cur.fetchall():
            if not sid or sid.startswith("zen-probe"):
                continue
            return sid
        con.close()
    except Exception as e:
        log(f"active_session erro: {e}")
    return None


def purge_probes():
    """Apaga as sessoes zen-probe (lixo de teste de cota)."""
    try:
        con = sqlite3.connect(DB, timeout=10)
        con.execute("PRAGMA busy_timeout=10000")
        ids = [x[0] for x in con.execute("SELECT id FROM session WHERE title='zen-probe'")]
        for sid in ids:
            con.execute("DELETE FROM part WHERE session_id=?", (sid,))
            con.execute("DELETE FROM message WHERE session_id=?", (sid,))
            con.execute("DELETE FROM session WHERE id=?", (sid,))
        con.commit()
        con.close()
        if ids:
            log(f"probes limpos: {len(ids)}")
    except Exception as e:
        log(f"purge_probes erro: {e}")


def wait_socks(timeout=15) -> bool:
    """Espera o SOCKS do WARP responder (evita 'socket closed' na rotação)."""
    end = time.time() + timeout
    while time.time() < end:
        r = subprocess.run(
            ["curl", "-s", "--max-time", "3", "--socks5-hostname",
             "127.0.0.1:40000", "https://api64.ipify.org"],
            capture_output=True, text=True)
        if r.stdout.strip():
            return True
        time.sleep(1)
    return False


def drop_tunnels():
    """Derruba os tuneis velhos do bridge: o servico reconecta no egress novo."""
    try:
        subprocess.run(["curl", "-s", "--max-time", "3",
                        "http://127.0.0.1:8898/rotate"],
                       capture_output=True, text=True, timeout=5)
        log("tuneis velhos derrubados (/rotate)")
    except Exception as e:
        log(f"/rotate falhou: {e}")


def _status(r, want=None) -> str:
    """Classifica o resultado de um request: quota | transient | ok | other."""
    out = (r.stdout or "") + (r.stderr or "")
    if LIMIT_PAT.search(out):
        return "quota"
    if TRANSIENT_PAT.search(out):
        return "transient"
    if r.returncode == 0 and out.strip():
        if want is None or want in out.lower():
            return "ok"
    return "other"


def test_quota(env) -> str:
    r = run([OPENCODE_BIN, "run", "-m", MODEL_FREE, "--title", "zen-probe",
             "responda apenas: ok"], env=env, timeout=120)
    st = _status(r, want="ok")
    purge_probes()
    return st


def resume(session_id: str | None, env) -> str:
    if not session_id:
        log("resume: nenhuma sessao ativa encontrada")
        return "other"
    r = run([OPENCODE_BIN, "run", "-s", session_id, "continue"], env=env, timeout=300)
    st = _status(r, want=None)
    log(f"resume {session_id} -> rc={r.returncode} status={st}")
    return st


def handle_limit(sid_hint: str | None = None) -> bool:
    """Gira ate achar um egress com cota; so gira de novo em cota real.
    Erros transitorios (peak demand, socket) tentam o MESMO bloco, sem queima-lo."""
    write_state(handling=True, handling_since=int(time.time()))
    sid = sid_hint or active_session()
    write_state(active_session=sid)
    # o bloco atual acabou de dar limit: marca como gasto antes de girar
    cur = egress_block()
    if cur:
        mark_spent(cur)
        log(f"bloco atual {cur} marcado como gasto (deu limit)")
    try:
        for attempt in range(1, MAXTRIES + 1):
            proxy = rotate()
            if proxy == "direct":
                log(f"tentativa {attempt}: rotacao falhou (direct), repetindo")
                time.sleep(3)
                continue
            blk = egress_block()
            if blk and blk in spent_today():
                log(f"tentativa {attempt}: bloco {blk} ja gasto hoje, pulando")
                time.sleep(2)
                continue
            if not wait_socks(15):
                log(f"tentativa {attempt}: SOCKS nao estabilizou, repetindo")
                time.sleep(2)
                continue
            env = proxy_env(proxy)
            status = test_quota(env)
            if status == "transient":
                for t in range(2, 4):  # so erro transitorio repete no MESMO bloco
                    log(f"  bloco {blk} tent {t}: transient, aguardando")
                    time.sleep(5)
                    status = test_quota(env)
                    if status in ("ok", "quota"):
                        break
            if status == "ok":
                drop_tunnels()
                log(f"cota ok na tentativa {attempt} via {proxy} ({blk or '?'})")
                write_state(last_ok=int(time.time()), last_proxy=proxy,
                            handling=False, fail_until=0)
                return True
            if status == "quota":
                if blk:
                    mark_spent(blk)
                log(f"tentativa {attempt}: sem cota via {proxy} ({blk or '?'})")
                time.sleep(3)
                continue
            # "other" (timeout/model lento) ou transient persistente:
            # o bloco NAO deu limit -> provavelmente tem cota. Derruba tuneis para
            # o servico reconectar no egress novo e considera recuperado (a proxima
            # mensagem do usuario ja passa pelo bloco novo, sem sair/entrar).
            drop_tunnels()
            log(f"tentativa {attempt}: {status} sem limit -> tuneis renovados ({blk or '?'})")
            write_state(last_ok=int(time.time()), last_proxy=proxy,
                        handling=False, fail_until=0)
            return True
        # esgotou rotacoes: nao entra em espiral, espera 10 min antes de tentar de novo
        NOTICE_FILE.write_text(
            f"{time.strftime('%Y-%m-%d %H:%M:%S')} esgotou {MAXTRIES} tentativas de rotacao\n",
            encoding="utf-8")
        log(f"FALHA: {MAXTRIES} tentativas sem cota -- backoff 10min")
        write_state(handling=False, fail_until=int(time.time()) + 600)
        return False
    finally:
        write_state(handling=False)


def tick():
    """Uma checagem: se lock ativo, ignora. Senao procura o erro no log recente."""
    lock_stale()
    if LOCK_FILE.exists():
        return
    if read_state().get("handling"):
        return
    try:
        tail = tail_bytes(LOG, 400_000)
    except Exception:
        return
    if LIMIT_PAT.search(tail):
        sid_hint = limit_session(tail)
        LOCK_FILE.write_text(str(os.getpid()), encoding="utf-8")
        try:
            handle_limit(sid_hint)
        finally:
            try:
                LOCK_FILE.unlink()
            except Exception:
                pass
        time.sleep(COOLDOWN)


def tail_bytes(path: Path, n: int) -> str:
    size = path.stat().st_size
    with path.open("rb") as f:
        if size > n:
            f.seek(-n, os.SEEK_END)
        return f.read().decode("utf-8", "replace")


def _warp_cli():
    for c in (shutil.which("warp-cli"), "/usr/bin/warp-cli"):
        if c:
            return c
    return None


_warp_last = [0.0]


def _warp_status(w):
    r = run([w, "status"], timeout=10)
    return (r.stdout or "") + (r.stderr or "")


def ensure_warp():
    """Mantem o WARP conectado. Se cair, reconecta; se faltar registro, cria um.
    Throttle de 15s. NUNCA re-registra em rajada (foi o que derrubou o WARP)."""
    if time.time() - _warp_last[0] < 15:
        return True
    _warp_last[0] = time.time()
    w = _warp_cli()
    if not w:
        return False
    if "Connected" in _warp_status(w):
        return True
    log("WARP caiu -> reconectando")
    run([w, "mode", "proxy"], timeout=15)
    run([w, "connect"], timeout=20)
    time.sleep(3)
    if "Connected" in _warp_status(w):
        log("WARP reconectado")
        return True
    run([w, "--accept-tos", "registration", "delete"], timeout=20)
    run([w, "--accept-tos", "registration", "new"], timeout=30)
    run([w, "connect"], timeout=20)
    time.sleep(3)
    ok = "Connected" in _warp_status(w)
    log(f"WARP restore -> {'ok' if ok else 'FALHOU (verifique manualmente)'}")
    return ok


def watch():
    log("zen_auto: vigia iniciado")
    # se morreu no meio de um handle (restart), o estado fica handling=true e trava tudo.
    # reseta aqui: sem sessao em andamento, o proximo limit dispara handle de novo.
    if read_state().get("handling"):
        log("handling travado de execucao anterior -> resetando")
        write_state(handling=False)
    pos = 0
    try:
        pos = LOG.stat().st_size
    except Exception:
        pass
    buf = ""
    while True:
        lock_stale()
        ensure_warp()
        # watchdog: se o handle pendurou (resume travado), des-trava apos 4 min
        st = read_state()
        if st.get("handling") and time.time() - int(st.get("handling_since", 0) or 0) > 420:
            log("watchdog: handling pendurado -> resetando")
            write_state(handling=False)
        st = read_state()
        if (not LOCK_FILE.exists() and not st.get("handling")
                and time.time() >= int(st.get("fail_until", 0) or 0)
                and Path(LOG).exists()):
            try:
                if Path(LOG).stat().st_size < pos:
                    pos = 0  # log rotacionou/encolheu: reinicia a leitura
                with LOG.open("rb") as f:
                    f.seek(pos)
                    chunk = f.read()
                    pos = f.tell()
                if chunk:
                    buf = (buf + chunk.decode("utf-8", "replace"))[-200_000:]
                    if LIMIT_PAT.search(buf):
                        sid_hint = limit_session(buf)
                        buf = ""
                        LOCK_FILE.write_text(str(os.getpid()), encoding="utf-8")
                        try:
                            handle_limit(sid_hint)
                        finally:
                            try:
                                LOCK_FILE.unlink()
                            except Exception:
                                pass
                        time.sleep(COOLDOWN)
            except Exception:
                pass
        time.sleep(3)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "watch"
    if cmd == "watch":
        watch()
    elif cmd == "once":
        tick()
    elif cmd == "rotate":
        p = rotate()
        st = test_quota(proxy_env(p))
        log(f"rotate manual -> {p} cota={st}")
        print(json.dumps({"proxy": p, "quota": st}))
        sys.exit(0 if st == "ok" else 1)
    elif cmd == "resume":
        sid = sys.argv[2] if len(sys.argv) > 2 else active_session()
        st = resume(sid, proxy_env("socks5://127.0.0.1:40000"))
        print(json.dumps({"session": sid, "status": st}))
        sys.exit(0 if st == "ok" else 1)
    elif cmd == "status":
        st = read_state()
        st["lock"] = LOCK_FILE.exists()
        st["active_session"] = active_session()
        st["log"] = str(LOG_FILE)
        print(json.dumps(st, indent=2))
    elif cmd == "stop":
        try:
            LOCK_FILE.unlink()
        except Exception:
            pass
        write_state(handling=False)
        print("parada marcada")
    else:
        sys.stderr.write(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
