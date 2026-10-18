#!/bin/bash
set -euo pipefail
ROOT=/opt/contoso-orderdesk
BASE=/var/lib/contoso-orderdesk
SNAPSHOT=/var/backups/contoso-orderdesk
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
require_root() { [[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }; }
lock_app() { exec 9>/var/lock/contoso-orderdesk.lock; flock -n 9 || { echo 'Another Order Desk operation is running.' >&2; exit 1; }; }
require_managed() {
    [[ -f $ROOT/.managed && ( -f $ROOT/.fresh-deployment || -f $SNAPSHOT/complete ) ]] || { echo 'No managed initial deployment or existing-lab snapshot found.' >&2; exit 1; }
}
require_tomcat101() {
    local version
    version=$(dpkg-query -W -f='${Version}' tomcat10)
    [[ $version == 10.1.* ]] || { echo "Expected Ubuntu Tomcat 10.1.x, got $version; stop and review repositories." >&2; exit 1; }
}
configured_port() {
    python3 - "$BASE/conf/server.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).getroot().find('Service/Connector').get('port'))
PY
}
wait_application() {
    local port=$1
    for attempt in {1..30}; do
        if python3 "$HERE/check.py" --base "http://127.0.0.1:$port" --health-only >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    echo 'Application liveness failed. Inspect the local service journal; do not paste credentials or the JNDI XML.' >&2
    return 1
}
