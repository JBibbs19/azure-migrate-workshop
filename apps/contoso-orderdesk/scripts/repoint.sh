#!/bin/bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
source "$HERE/common.sh"
require_root
lock_app
require_managed
[[ $# == 3 ]] || { echo 'Usage: sudo bash repoint.sh <new-SQL-IP> <new-App-IP> <new-Nginx-IP>' >&2; exit 1; }
systemctl stop contoso-orderdesk-traffic.service
python3 "$HERE/hosts.py" --sql "$1" --app "$2" --nginx "$3"
# Close the old SQL pool and resolve the new target on the next connection.
systemctl restart contoso-orderdesk.service
wait_application "$(configured_port)"
python3 "$HERE/check.py" --base "http://127.0.0.1:$(configured_port)"
echo 'Guest aliases repointed. Update Linux-Web and Windows IIS/SQL aliases too, then explicitly re-enable replacement traffic.'
