#!/bin/bash
# Run on OnPrem-Linux-App, never on HyperVHost or the build container.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
source "$HERE/common.sh"
require_root
lock_app
BUNDLE=$(cd "$HERE/.." && pwd)
JDBC=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jdbc-jar) [[ $# -ge 2 ]] || { echo 'Missing JDBC path.' >&2; exit 1; }; JDBC=$2; shift 2 ;;
        *) echo 'Usage: sudo bash scripts/install.sh --jdbc-jar /path/mssql-jdbc-<version>.jre11.jar' >&2; exit 1 ;;
    esac
done
[[ -n $JDBC && -f $JDBC ]] || { echo 'Official Microsoft JDBC jre11 JAR is required; nothing was installed.' >&2; exit 1; }
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || { echo 'This installer is scoped to the existing Ubuntu 24.04 guest.' >&2; exit 1; }
python3 "$HERE/driver_check.py" "$JDBC"
(cd "$BUNDLE" && sha256sum --check --quiet SHA256SUMS)
if [[ -e $ROOT && ! -f $ROOT/.managed ]]; then echo 'Dedicated deployment path already exists but is not managed; refusing overwrite.' >&2; exit 1; fi
if id contoso-orderdesk >/dev/null 2>&1 && [[ ! -f $ROOT/.managed && ! -f $SNAPSHOT/complete ]]; then
    echo 'The dedicated account already exists without a prior lab snapshot; refusing to reuse a non-lab account.' >&2; exit 1
fi
if [[ ! -f $ROOT/.managed ]]; then
    for path in "$BASE" /etc/systemd/system/contoso-orderdesk.service /etc/systemd/system/contoso-orderdesk-traffic.service /etc/contoso-orderdesk-traffic.json; do
        [[ ! -e $path && ! -L $path ]] || { echo "Non-managed path already exists: $path. Refusing overwrite." >&2; exit 1; }
    done
fi
if [[ -f $BASE/conf/server.xml && $(configured_port) == 3000 ]]; then
    echo 'Already switched to port 3000. Do not restage a live deployment; validate it or roll back first.' >&2; exit 1
fi
if systemctl is-active --quiet tomcat10.service; then
    echo 'An existing stock Tomcat service is running. Do not overwrite or stop non-lab applications; review it first.' >&2; exit 1
fi
python3 "$HERE/snapshot.py" save "$SNAPSHOT"
install -d -m 0755 "$ROOT" "$ROOT/scripts" "$ROOT/dist"
printf '%s\n' 'Contoso Order Desk 1.0.0' > "$ROOT/.managed"
cp "$HERE/"*.py "$HERE/"*.sh "$HERE/"*.service "$HERE/"*.service.in "$ROOT/scripts/"
cp "$BUNDLE/dist/contoso-orderdesk.war" "$ROOT/dist/"
chmod 0644 "$ROOT/scripts/"* "$ROOT/dist/"*
chmod 0755 "$ROOT/scripts/"*.sh
chown -R root:root "$ROOT"
# Do not modify the Node files, npm modules, credentials or old traffic unit.
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y tomcat10 openjdk-17-jre-headless curl python3 iproute2 net-tools
require_tomcat101
if python3 - "$SNAPSHOT/manifest.json" <<'PY'
import json, sys
services = json.load(open(sys.argv[1]))['services']
sys.exit(0 if next(s for s in services if s['unit'] == 'tomcat10.service')['enabled'] == 'not-found' else 1)
PY
then
    systemctl disable --now tomcat10.service
fi
JAVA_HOME="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)"
[[ -x $JAVA_HOME/bin/java && -x /usr/share/tomcat10/bin/catalina.sh && -f /etc/tomcat10/web.xml ]] || {
    echo 'Expected Ubuntu Tomcat 10.1 / OpenJDK 17 package layout is missing. Stop and inspect package versions.' >&2; exit 1;
}
python3 - <<'PY'
from pathlib import Path
import zipfile
found = False
for path in Path('/usr/share/tomcat10/lib').glob('*.jar'):
    with zipfile.ZipFile(path) as jar:
        if 'org/apache/tomcat/jdbc/pool/DataSourceFactory.class' in jar.namelist():
            found = True
if not found:
    raise SystemExit('Ubuntu Tomcat JDBC pool factory is missing. Do not continue with an unbounded or absent pool.')
PY
if ! id contoso-orderdesk >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --home-dir "$BASE" --shell /usr/sbin/nologin contoso-orderdesk
fi
[[ $(id -u contoso-orderdesk) -ne 0 && $(getent passwd contoso-orderdesk | cut -d: -f7) == /usr/sbin/nologin ]] || {
    echo 'Dedicated runtime account is not the expected non-root service account.' >&2; exit 1;
}
systemctl stop contoso-orderdesk.service 2>/dev/null || true
python3 "$ROOT/scripts/configure.py" init --bundle "$ROOT"
install -m 0644 "$JDBC" "$BASE/lib/mssql-jdbc.jre11.jar"
chown -R root:contoso-orderdesk "$BASE/conf" "$BASE/lib" "$BASE/webapps"
find "$BASE/conf" -type d -exec chmod 0755 {} +
find "$BASE/lib" "$BASE/webapps" -type d -exec chmod 0755 {} +
find "$BASE/conf" "$BASE/lib" "$BASE/webapps" -type f ! -name ROOT.xml -exec chmod 0644 {} +
chmod 0640 "$BASE/conf/Catalina/localhost/ROOT.xml"
chmod 0755 "$BASE"
chown contoso-orderdesk:contoso-orderdesk "$BASE/logs" "$BASE/work" "$BASE/temp"
chmod 0755 "$BASE/logs" "$BASE/work" "$BASE/temp"
sed "s|__JAVA_HOME__|$JAVA_HOME|g" "$ROOT/scripts/contoso-orderdesk.service.in" > /etc/systemd/system/contoso-orderdesk.service
install -m 0644 "$ROOT/scripts/contoso-orderdesk-traffic.service" /etc/systemd/system/contoso-orderdesk-traffic.service
python3 "$ROOT/scripts/configure.py" traffic
python3 "$ROOT/scripts/hosts.py"
# Reruns retain the first snapshot and the existing SQL password, not a new baseline.
systemctl daemon-reload
systemctl enable contoso-orderdesk.service
systemctl restart contoso-orderdesk.service
wait_application 3001
{
    printf 'Target package inventory (verify at deployment; no patch version was assumed):\n'
    dpkg-query -W -f='${Package} ${Version}\n' tomcat10 tomcat10-common libtomcat10-java openjdk-17-jre-headless
    "$JAVA_HOME/bin/java" -version 2>&1
    python3 "$ROOT/scripts/driver_check.py" "$JDBC"
} > "$ROOT/installed-versions.txt"
chmod 0644 "$ROOT/installed-versions.txt"
python3 "$ROOT/scripts/check.py" --base http://127.0.0.1:3001
printf '\nStaging is ready on 3001. Node port 3000 and old traffic were NOT stopped.\nReview installed-versions.txt, run a staging write check, then invoke switch.sh explicitly.\n'
