#!/bin/bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
source "$HERE/common.sh"
require_root
require_managed
USER_TO_CHECK=''
WRITE=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --credential-user) [[ $# -ge 2 ]] || exit 1; USER_TO_CHECK=$2; shift 2 ;;
        --write) WRITE=--write; shift ;;
        *) echo 'Usage: sudo bash validate.sh [--credential-user labadmin] [--write]' >&2; exit 1 ;;
    esac
done
require_tomcat101
python3 "$HERE/configure.py" layout
port=$(configured_port)
python3 "$HERE/check.py" --base "http://127.0.0.1:$port" ${WRITE:+$WRITE}
systemctl is-active --quiet contoso-orderdesk.service
[[ $(stat -c '%a:%U:%G' "$BASE/conf/Catalina/localhost/ROOT.xml") == 640:root:contoso-orderdesk ]] || {
    echo 'FAIL: credentials descriptor permissions are not root:runtime 640.' >&2; exit 1;
}
environment=$(systemctl show contoso-orderdesk.service --property=Environment --value)
[[ " $environment " == *' CATALINA_HOME=/opt/tomcat '* && " $environment " == *' CATALINA_BASE=/opt/tomcat '* &&
   " $environment " == *' JAVA_HOME=/usr/lib/jvm/java-17-openjdk-'* ]] || { echo 'FAIL: running service environment is not the unified Java 17 tree.' >&2; exit 1; }
[[ $(systemctl show contoso-orderdesk.service --property=WorkingDirectory --value) == "$BASE" &&
   $(systemctl show contoso-orderdesk.service --property=User --value) == contoso-orderdesk &&
   $(systemctl show contoso-orderdesk.service --property=ExecStart --value) == *'path=/opt/tomcat/bin/catalina.sh ;'* ]] || {
    echo 'FAIL: running service launch path/account is not the unified runtime.' >&2; exit 1;
}
sudo -u contoso-orderdesk -- test -r "$BASE/conf/Catalina/localhost/ROOT.xml"
echo 'PASS: dedicated JVM service active; credentials descriptor restricted to root/runtime.'
if [[ -n $USER_TO_CHECK ]]; then
    id "$USER_TO_CHECK" >/dev/null
    sudo -u "$USER_TO_CHECK" -- /bin/bash -s -- "$BASE" <<'SH'
set -euo pipefail
for home in "$@"; do
    [[ -r $home && -x $home ]] || { echo 'FAIL: Tomcat directory is not readable/traversable.' >&2; exit 1; }
    directories=$(find "$home" -type d -print)
    while IFS= read -r dir; do
        [[ -r $dir && -x $dir ]] || { printf 'FAIL: directory read/execute access: %s\n' "$dir"; exit 1; }
    done <<< "$directories"
done
sudo -n ls /opt/tomcat >/dev/null
sudo -n netstat -ntp >/dev/null
echo 'PASS: discovery login has recursive CATALINA_HOME/BASE directory read/execute and sudo ls/netstat.'
SH
    if sudo -u "$USER_TO_CHECK" -- test -r "$BASE/conf/Catalina/localhost/ROOT.xml"; then
        echo 'WARNING: this credential can read SQL secrets (root/runtime-group membership or other access). Review least privilege.'
    else
        echo 'PASS: discovery login cannot read the SQL password descriptor.'
    fi
fi
echo 'These are LOCAL permission/HTTP checks, not proof of Azure Migrate appliance SSH reachability or discovery.'
