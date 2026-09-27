#!/bin/sh
# Wer baut gerade was: die Runner der Registry gegen die Jobs der laufenden
# Laeufe gestellt.
#
#   scripts/ci-runners.sh [repo]        # default: ddimension/openwrt-repo
#
# Ausgabe: je Runner Status, busy, der gefahrene Job (Lauf, Leg, Laufzeit);
# darunter die Legs, die noch auf einen freien Runner warten, die bereits
# fertigen Legs des juengsten Laufs mit Laufzeit, und die aktiven Laeufe.
#
# Worauf zu achten ist: ein Runner mit **busy=ja, aber ohne Job** ist die
# Karteileiche eines verschwundenen Hosts. GitHub haelt dessen Zuweisung, bis
# seine Frist fuer verlorene Runner ablaeuft (bis zu einer Stunde); bis dahin
# antwortet das Deregistrieren mit "currently running a job and cannot be
# deleted", und weder `gh run cancel` noch `force-cancel` beschleunigen das —
# ein abgebrochener Lauf gilt erst als beendet, wenn der Runner es quittiert.
set -eu

REPO="${1:-ddimension/openwrt-repo}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

gh api "repos/$REPO/actions/runners" >"$TMP/runners.json"
gh run list -R "$REPO" -L 12 \
	--json databaseId,status,workflowName,displayTitle,createdAt >"$TMP/runs.json"

# Jobs jedes aktiven Laufs dazu; ein Lauf ohne Jobs (noch nicht verteilt)
# liefert einfach eine leere Liste.
active="$(python3 -c '
import json
for r in json.load(open("'"$TMP"'/runs.json")):
    if r["status"] in ("in_progress", "queued", "pending"):
        print(r["databaseId"])
')"
for id in $active; do
	gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" >"$TMP/jobs-$id.json" || true
done

TMP="$TMP" python3 <<'PY'
import datetime
import glob
import json
import os

tmp = os.environ["TMP"]
now = datetime.datetime.now(datetime.timezone.utc)


def age(ts):
    if not ts:
        return ""
    t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
    return "%d min" % ((now - t.replace(tzinfo=datetime.timezone.utc)).total_seconds() // 60)


def span(a, b):
    if not a or not b:
        return ""
    f = "%Y-%m-%dT%H:%M:%SZ"
    return "%d min" % ((datetime.datetime.strptime(b, f) - datetime.datetime.strptime(a, f)).total_seconds() // 60)


runners = json.load(open(f"{tmp}/runners.json")).get("runners", [])
runs = json.load(open(f"{tmp}/runs.json"))

running, waiting, done = {}, [], []
for path in sorted(glob.glob(f"{tmp}/jobs-*.json")):
    run_id = path.rsplit("-", 1)[1].split(".")[0]
    for j in json.load(open(path)).get("jobs", []):
        name = j.get("name", "")[:46]
        if j.get("status") == "in_progress" and j.get("runner_name"):
            running[j["runner_name"]] = (run_id, name, age(j.get("started_at")))
        elif j.get("status") in ("queued", "pending"):
            waiting.append((run_id, name))
        elif j.get("conclusion"):
            done.append((j.get("runner_name") or "-", j["conclusion"], name,
                         span(j.get("started_at"), j.get("completed_at"))))

fmt = "%-7s %-8s %-5s %-12s %-46s %s"
print(fmt % ("runner", "status", "busy", "lauf", "job", "laeuft"))
for r in sorted(runners, key=lambda x: (len(x["name"]), x["name"])):
    job = running.get(r["name"])
    note = "" if job else ("KARTEILEICHE: busy ohne Job" if r["busy"] else "-")
    print(fmt % (r["name"], r["status"], "ja" if r["busy"] else "nein",
                 job[0] if job else "-", job[1] if job else note, job[2] if job else ""))

if waiting:
    print("\nwartende Legs ohne Runner: %d" % len(waiting))
    for run_id, name in waiting[:10]:
        print("   %-12s %s" % (run_id, name))

if done:
    print("\nfertige Legs:")
    for runner, concl, name, dur in sorted(done, key=lambda x: (x[1] != "success", x[0]))[:12]:
        print("   %-7s %-9s %-46s %s" % (runner, concl, name, dur))

print("\nLaeufe:")
for r in runs:
    if r["status"] in ("in_progress", "queued", "pending"):
        print("   %-12s %-22s %-11s %s" % (r["databaseId"], r["workflowName"][:22],
                                           r["status"], r["displayTitle"][:34]))
PY
