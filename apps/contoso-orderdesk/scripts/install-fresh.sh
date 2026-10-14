#!/bin/bash
# Initial cloud-init only: packages are installed by the cloud-config packages directive.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
source "$HERE/common.sh"
require_root
lock_app
BUNDLE=$(cd "$HERE/.." && pwd)
SEED=/root/contoso-sql-password.json
trap 'rm -f "$SEED" /root/contoso-runtime.zip' EXIT
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || { echo 'Initial installer requires Ubuntu 24.04.' >&2; exit 1; }
(cd "$BUNDLE" && sha256sum --check --quiet RUNTIME-SHA256SUMS)
[[ -f $SEED ]] || { echo 'Protected initial SQL seed missing.' >&2; exit 1; }
for path in "$ROOT" "$BASE" /etc/systemd/system/contoso-orderdesk.service; do
    [[ ! -e $path && ! -L $path ]] || { echo 'Initial deployment paths are occupied; this installer is not an updater.' >&2; exit 1; }
done
require_tomcat101
systemctl disable --now tomcat10.service
JAVA_HOME="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)"
[[ -x $JAVA_HOME/bin/java && -x /usr/share/tomcat10/bin/catalina.sh && -f /etc/tomcat10/web.xml ]] || {
    echo 'Ubuntu Tomcat 10.1 / OpenJDK 17 layout missing; inspect package installation.' >&2; exit 1;
}
python3 - <<'PY'
from pathlib import Path
import zipfile
found = False
for path in Path('/usr/share/tomcat10/lib').glob('*.jar'):
    with zipfile.ZipFile(path) as jar:
        found |= 'org/apache/tomcat/jdbc/pool/DataSourceFactory.class' in jar.namelist()
if not found:
    raise SystemExit('Required Tomcat JDBC pool factory is missing.')
PY
JDBC="$BUNDLE/jdbc/mssql-jdbc-13.6.0.jre11.jar"
if [[ -f $BUNDLE/jdbc/SHA256SUMS ]]; then
    (cd "$BUNDLE/jdbc" && sha256sum --check --quiet SHA256SUMS)
else
    install -d -m 0700 "$BUNDLE/jdbc"
    # Pinned publisher coordinate, HTTPS, bounded download. Structural checks are not signature verification.
    if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 --location --fail --silent --show-error \
        --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 5 --retry-max-time 600 \
        --output "$JDBC" \
        'https://repo.maven.apache.org/maven2/com/microsoft/sqlserver/mssql-jdbc/13.6.0.jre11/mssql-jdbc-13.6.0.jre11.jar'; then
        rm -f "$JDBC"
        echo 'Pinned official JDBC download failed. Use the deploy -TomcatJdbcJar and -TomcatJdbcSha256 local prerequisite route, then rebuild the incomplete host.' >&2
        exit 1
    fi
fi
python3 "$HERE/driver_check.py" "$JDBC"
if id contoso-orderdesk >/dev/null 2>&1; then
    echo 'Dedicated runtime account already exists on a fresh guest; refusing reuse.' >&2; exit 1
fi
useradd --system --user-group --no-create-home --home-dir "$BASE" --shell /usr/sbin/nologin contoso-orderdesk
[[ $(id -u contoso-orderdesk) -ne 0 ]] || exit 1
install -d -m 0755 "$ROOT" "$ROOT/scripts" "$ROOT/dist"
cp "$HERE/"*.py "$HERE/"*.sh "$HERE/"*.service "$HERE/"*.service.in "$ROOT/scripts/"
cp "$BUNDLE/dist/contoso-orderdesk.war" "$ROOT/dist/"
chmod 0644 "$ROOT/scripts/"* "$ROOT/dist/"*
chmod 0755 "$ROOT/scripts/"*.sh
chown -R root:root "$ROOT"
printf '%s\n' 'Contoso Order Desk 1.0.0' > "$ROOT/.managed"
printf '%s\n' 'Initial provisioning; no previous application to restore.' > "$ROOT/.fresh-deployment"
python3 "$ROOT/scripts/configure.py" init --bundle "$ROOT" --port 3000 --password-file "$SEED"
install -m 0644 "$JDBC" "$BASE/lib/mssql-jdbc.jre11.jar"
chown -R root:contoso-orderdesk "$BASE/conf" "$BASE/lib" "$BASE/webapps"
find "$BASE/conf" "$BASE/lib" "$BASE/webapps" -type d -exec chmod 0755 {} +
find "$BASE/conf" "$BASE/lib" "$BASE/webapps" -type f ! -name ROOT.xml -exec chmod 0644 {} +
chmod 0640 "$BASE/conf/Catalina/localhost/ROOT.xml"
chmod 0755 "$BASE"
chown contoso-orderdesk:contoso-orderdesk "$BASE/logs" "$BASE/work" "$BASE/temp"
# Directory read/execute permits discovery; the private JNDI descriptor remains separately protected.
chmod 0755 "$BASE/logs" "$BASE/work" "$BASE/temp"
sed "s|__JAVA_HOME__|$JAVA_HOME|g" "$ROOT/scripts/contoso-orderdesk.service.in" > /etc/systemd/system/contoso-orderdesk.service
install -m 0644 "$ROOT/scripts/contoso-orderdesk-traffic.service" /etc/systemd/system/contoso-orderdesk-traffic.service
python3 "$ROOT/scripts/configure.py" traffic
python3 "$ROOT/scripts/hosts.py"
systemctl daemon-reload
systemctl enable --now contoso-orderdesk.service
wait_application 3000
{
    printf 'Target package inventory (actual installed versions):\n'
    dpkg-query -W -f='${Package} ${Version}\n' tomcat10 tomcat10-common libtomcat10-java openjdk-17-jre-headless
    "$JAVA_HOME/bin/java" -version 2>&1
    python3 "$ROOT/scripts/driver_check.py" "$JDBC"
} > "$ROOT/installed-versions.txt"
chmod 0644 "$ROOT/installed-versions.txt"
python3 "$ROOT/scripts/check.py" --base http://127.0.0.1:3000 --health-only
printf '%s\n' 'LAB_TOMCAT_LIVENESS_OK - SQL readiness is validated by the host after database preparation.'
