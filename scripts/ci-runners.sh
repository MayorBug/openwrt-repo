#!/bin/sh
# Wer baut gerade was — mit Fortschritt und ETA, sobald es etwas zu rechnen gibt.
#
#   scripts/ci-runners.sh [repo] [historie]   # default: ddimension/openwrt-repo, 25
#
# Ausgabe: je Runner der Job (Leg, Laufzeit, Balken, Restzeit), die Legs ohne
# Runner, die fertigen Legs des Laufs, und je Lauf Fortschritt und ETA.
#
# Woher die ETA kommt: Basiszeit eines Legs ist der Median derselben Kombination
# <release>/<arch> aus **erfolgreichen Matrix-Legs** — zuerst aus dem laufenden
# Lauf (gleiche Runner, gleicher Cache: der beste Vergleich, Marke "lauf"), sonst
# aus den letzten Laeufen ("hist"), sonst der Median ueber alle Matrix-Legs
# ("grob"). Nur Matrix-Legs, denn `feed`, `publish` und die ImageBuilder-Legs
# dauern Minuten und wuerden jeden Schnitt unbrauchbar machen.
#
# Wie genau das ist: die Historie stammt von den Runnern, die damals liefen.
# Andere Kernzahl oder leere dl/ccache-Volumes verschieben das deutlich nach
# oben — eine "hist"- oder "grob"-ETA ist eine untere Schranke, keine Zusage.
# Ohne jede Grundlage steht "—" statt einer erfundenen Zahl.
#
# Worauf zu achten ist: ein Runner mit **busy=ja, aber ohne Job** ist die
# Karteileiche eines verschwundenen Hosts. GitHub haelt dessen Zuweisung, bis
# seine Frist fuer verlorene Runner ablaeuft (bis zu einer Stunde); bis dahin
# antwortet das Deregistrieren mit "currently running a job and cannot be
# deleted", und weder `gh run cancel` noch `force-cancel` beschleunigen das —
# ein abgebrochener Lauf gilt erst als beendet, wenn der Runner es quittiert.
set -eu

REPO="${1:-ddimension/openwrt-repo}"
# 25 abgeschlossene Laeufe als Fenster, nicht ein Dutzend: ein abgebrochener
# Lauf liefert keine Messwerte, und in Push-reichen Naechten sind die meisten
# abgebrochen — mit 12 fielen fuenf Kombinationen auf "grob" zurueck, mit 25
# nur noch zwei.
HIST="${2:-25}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

gh api "repos/$REPO/actions/runners" >"$TMP/runners.json"
gh run list -R "$REPO" -L 30 \
	--json databaseId,status,workflowName,displayTitle,createdAt >"$TMP/runs.json"

# Jobs der aktiven Laeufe (Fortschritt) und der letzten abgeschlossenen
# (Basiszeiten). Die aktiven stehen in active.txt, damit die Auswertung beide
# Quellen auseinanderhalten kann.
TMP="$TMP" HIST="$HIST" python3 -c '
import json, os
runs = json.load(open(os.environ["TMP"] + "/runs.json"))
active = [str(r["databaseId"]) for r in runs if r["status"] in ("in_progress", "queued", "pending")]
done = [str(r["databaseId"]) for r in runs if str(r["databaseId"]) not in active][: int(os.environ["HIST"])]
open(os.environ["TMP"] + "/active.txt", "w").write("\n".join(active))
open(os.environ["TMP"] + "/fetch.txt", "w").write("\n".join(active + done))
'
while read -r id; do
	[ -n "$id" ] || continue
	gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" >"$TMP/jobs-$id.json" || true
done <"$TMP/fetch.txt"

TMP="$TMP" python3 <<'PY'
import datetime
import glob
import json
import os
import statistics

tmp = os.environ["TMP"]
now = datetime.datetime.now(datetime.timezone.utc)
F = "%Y-%m-%dT%H:%M:%SZ"
active = {x for x in open(f"{tmp}/active.txt").read().split() if x}


def ts(s):
    return datetime.datetime.strptime(s, F).replace(tzinfo=datetime.timezone.utc) if s else None


def is_matrix(name):
    """Nur die Matrix-Legs des Feed-Baus: 'build (<release>, <arch>)'."""
    return name.startswith("build (") and name.endswith(")")


def leg_key(name):
    if "(" in name and ")" in name:
        parts = [p.strip() for p in name[name.index("(") + 1: name.rindex(")")].split(",")]
        if len(parts) >= 2:
            return f"{parts[0]}/{parts[1]}"
    return name.strip()


runners = json.load(open(f"{tmp}/runners.json")).get("runners", [])
runs = {str(r["databaseId"]): r for r in json.load(open(f"{tmp}/runs.json"))}

running, waiting, finished = [], [], []      # finished: (run, runner, concl, key, min)
base_run, base_hist = {}, {}
for path in sorted(glob.glob(f"{tmp}/jobs-*.json")):
    rid = path.rsplit("-", 1)[1].split(".")[0]
    for j in json.load(open(path)).get("jobs", []):
        name, key = j.get("name", ""), leg_key(j.get("name", ""))
        st, concl = j.get("status"), j.get("conclusion")
        if concl and j.get("started_at") and j.get("completed_at"):
            mins = (ts(j["completed_at"]) - ts(j["started_at"])).total_seconds() / 60
            if concl == "success" and is_matrix(name):
                (base_run if rid in active else base_hist).setdefault(key, []).append(mins)
            if rid in active:
                finished.append((rid, j.get("runner_name") or "-", concl, key, mins))
        elif st == "in_progress" and j.get("runner_name"):
            running.append((j["runner_name"], rid, key, ts(j.get("started_at")), is_matrix(name)))
        elif st in ("queued", "pending"):
            waiting.append((rid, key, is_matrix(name)))

matrix_all = [m for v in list(base_run.values()) + list(base_hist.values()) for m in v]
GLOBAL = statistics.median(matrix_all) if matrix_all else None


def baseline(key, matrix):
    """(minuten, quelle) — 'lauf' schlaegt 'hist' schlaegt 'grob'."""
    if key in base_run:
        return statistics.median(base_run[key]), "lauf"
    if key in base_hist:
        return statistics.median(base_hist[key]), "hist"
    return (GLOBAL, "grob") if (GLOBAL and matrix) else (None, None)


def bar(frac, width=14):
    frac = max(0.0, min(1.0, frac))
    return "█" * int(frac * width) + "░" * (width - int(frac * width))


def hhmm(dt):
    return dt.strftime("%H:%M") + "Z"


fmt = "%-7s %-8s %-5s %-30s %7s  %-14s %s"
print(fmt % ("runner", "status", "busy", "leg", "laeuft", "fortschritt", "rest/eta"))
by_runner = {r[0]: r for r in running}
for r in sorted(runners, key=lambda x: (len(x["name"]), x["name"])):
    job = by_runner.get(r["name"])
    if not job:
        note = "KARTEILEICHE: busy ohne Job" if r["busy"] else "-"
        print(fmt % (r["name"], r["status"], "ja" if r["busy"] else "nein", note, "", "", ""))
        continue
    _, rid, key, start, matrix = job
    el = (now - start).total_seconds() / 60 if start else 0
    b, tag = baseline(key, matrix)
    if not b:
        prog, eta = "", "— (keine Basiszeit)"
    elif el <= b:
        prog, eta = bar(el / b), "~%s (%s)" % (hhmm(now + datetime.timedelta(minutes=b - el)), tag)
    elif tag == "lauf":
        prog, eta = bar(1.0), "ueberfaellig +%.0f min" % (el - b)
    else:
        # hist/grob sind untere Schranken: daraus kein "ueberfaellig" behaupten
        prog, eta = bar(0.95), "ueber der %s-Schaetzung (+%.0f min)" % (tag, el - b)
    print(fmt % (r["name"], r["status"], "ja", key[:30], "%.0f min" % el, prog, eta))

if waiting:
    print("\nwartende Legs ohne Runner: %d" % len(waiting))
    for rid, key, _m in waiting[:10]:
        print("   %-12s %s" % (rid, key))

fin_active = [f for f in finished]
if fin_active:
    print("\nfertige Legs der laufenden Laeufe:")
    for rid, runner, concl, key, mins in sorted(fin_active, key=lambda x: (x[2] != "success", x[4]))[:12]:
        print("   %-7s %-9s %-30s %.0f min" % (runner, concl, key[:30], mins))

print("\nLaeufe:")
idle_runners = len([x for x in runners if not x["busy"]])
for rid in sorted(active):
    r = runs.get(rid)
    if not r:
        continue
    run_running = [x for x in running if x[1] == rid]
    run_wait = [x for x in waiting if x[0] == rid]
    run_done = [f for f in finished if f[0] == rid]
    total = len(run_done) + len(run_running) + len(run_wait)
    # ETA: freie Runner koennen sofort, die beschaeftigten erst nach ihrer Restzeit
    free = [0.0] * idle_runners
    for _rn, _rid, key, start, matrix in run_running:
        b, _t = baseline(key, matrix)
        el = (now - start).total_seconds() / 60 if start else 0
        free.append(max((b - el) if b else 5.0, 0.5))
    unknown = False
    for _rid, key, matrix in run_wait:
        b, _t = baseline(key, matrix)
        if b is None:
            unknown = True
            b = GLOBAL or 0
        if not free:
            free = [b]
            continue
        free.sort()
        free[0] += b
    eta = "—" if (not free or unknown and not GLOBAL) else "~%s" % hhmm(now + datetime.timedelta(minutes=max(free)))
    print("   %-12s %-20s %-11s %2d/%-2d fertig %s  ETA %s"
          % (rid, r["workflowName"][:20], r["status"], len(run_done), total,
             bar(len(run_done) / total if total else 0), eta))
    print("   %-12s %s" % ("", r["displayTitle"][:64]))
PY
