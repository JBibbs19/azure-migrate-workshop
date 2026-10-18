#!/bin/bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
source "$HERE/common.sh"
require_root
lock_app
require_managed
[[ ! -f $ROOT/.fresh-deployment && -f $SNAPSHOT/complete ]] || {
    echo 'Rollback is only for a captured existing-lab installation, not an initial Tomcat deployment.' >&2; exit 1
}
[[ ${1:-} == --restore-original ]] || {
    echo 'Review the snapshot first: sudo python3 /opt/contoso-orderdesk/scripts/snapshot.py show /var/backups/contoso-orderdesk'
    echo 'Then run rollback.sh --restore-original. This restores /etc/hosts as captured; later manual edits must be reconciled first.' >&2
    exit 1
}
# Run helpers before deleting their own installation directory.
systemctl disable --now contoso-orderdesk-traffic.service contoso-orderdesk.service
python3 "$HERE/snapshot.py" restore-files "$SNAPSHOT"
rm -f /etc/systemd/system/contoso-orderdesk.service /etc/systemd/system/contoso-orderdesk-traffic.service /etc/contoso-orderdesk-traffic.json
systemctl daemon-reload
python3 "$HERE/snapshot.py" restore-services "$SNAPSHOT"
if python3 - "$SNAPSHOT/manifest.json" <<'PY'
import json, sys
services = json.load(open(sys.argv[1]))['services']
sys.exit(0 if next(s for s in services if s['unit'] == 'contoso-app.service')['active'] == 'active' else 1)
PY
then
    python3 - <<'PY'
import json, time, urllib.error, urllib.request
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
for attempt in range(15):
    try:
        with opener.open('http://127.0.0.1:3000/api/health', timeout=5) as response:
            health = json.load(response)
        break
    except (urllib.error.URLError, OSError):
        time.sleep(2)
else:
    raise SystemExit('Original Node health did not recover; inspect contoso-app locally.')
if health.get('status') != 'healthy' or health.get('server') != 'OnPrem-Linux-App' or health.get('app') == 'Contoso Order Desk':
    raise SystemExit('Original Node health response was not restored; inspect contoso-app locally.')
print('Original Node health contract verified on port 3000.')
PY
fi
# Only remove paths originally proven absent and subsequently marked as ours.
rm -rf -- "$BASE" "$ROOT"
printf 'Original application files, traffic credentials, hosts and service states restored.\nSnapshot retained at %s. Ubuntu packages, the inactive runtime account, SQL rows/login and IIS task are intentionally retained.\nIf proxy.sh changed Linux-Web, run its separate rollback there.\n' "$SNAPSHOT"
