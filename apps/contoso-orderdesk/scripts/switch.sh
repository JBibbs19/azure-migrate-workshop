#!/bin/bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
source "$HERE/common.sh"
require_root
lock_app
require_managed
if [[ $(configured_port) == 3000 ]]; then
    python3 "$HERE/check.py" --base http://127.0.0.1:3000
    echo 'Already switched; original rollback snapshot retained. No traffic service was changed.'
    exit 0
fi
[[ $(configured_port) == 3001 ]] || { echo 'Unexpected configured port; no services changed.' >&2; exit 1; }
python3 "$HERE/check.py" --base http://127.0.0.1:3001
command -v ss >/dev/null || { echo 'Install iproute2 on this guest; ss is required to verify port ownership.' >&2; exit 1; }
pid=$(systemctl show contoso-app.service --property=MainPID --value 2>/dev/null || true)
listeners=$(ss -H -lntp 'sport = :3000')
if [[ -n $listeners ]]; then
    while IFS= read -r listener; do
        [[ -n $pid && $pid != 0 && $listener == *"pid=$pid,"* ]] || {
            echo 'Port 3000 is owned by something other than the original contoso-app service; refusing cutover.' >&2; exit 1;
        }
    done <<< "$listeners"
fi
recover_staging() {
    local code=$?
    trap - ERR
    echo 'Cutover failed. Returning Tomcat to staging and restoring original Node/traffic running and enablement states.' >&2
    systemctl stop contoso-orderdesk-traffic.service contoso-orderdesk.service || true
    python3 "$HERE/configure.py" port --port 3001 || true
    python3 "$HERE/snapshot.py" restore-services "$SNAPSHOT" || true
    systemctl start contoso-orderdesk.service || true
    echo 'Check both services. The original snapshot is retained; rollback.sh remains available.' >&2
    exit "$code"
}
trap recover_staging ERR
# Stop BOTH Node units; disabling only the web service leaves SQL traffic outside Tomcat.
for unit in lab-traffic.service contoso-app.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then systemctl disable --now "$unit"; fi
done
systemctl stop contoso-orderdesk.service
python3 "$HERE/configure.py" port --port 3000
systemctl start contoso-orderdesk.service
wait_application 3000
python3 "$HERE/check.py" --base http://127.0.0.1:3000
trap - ERR
printf 'Cutover verified on 3000. Original Node files and credentials are retained for rollback.\nNginx API forwarding and IIS health calls keep their existing URLs. Replacement traffic is still opt-in.\n'
