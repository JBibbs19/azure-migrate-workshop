#!/bin/bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
source "$HERE/common.sh"
require_root
lock_app
require_managed
case "${1:-}" in
    on)
        [[ $(configured_port) == 3000 ]] || { echo 'Switch to 3000 before enabling replacement traffic.' >&2; exit 1; }
        interval=${2:-30}
        python3 "$HERE/configure.py" traffic --interval "$interval"
        python3 "$HERE/check.py" --base http://127.0.0.1:3000
        python3 "$HERE/check.py" --base http://onprem-nginx:8080 --api-only
        if systemctl is-active --quiet lab-traffic.service; then
            echo 'Original Node generator is still active; do not run two generators.' >&2; exit 1
        fi
        systemctl enable --now contoso-orderdesk-traffic.service
        sleep 2
        systemctl is-active --quiet contoso-orderdesk-traffic.service
        echo "HTTP-only traffic enabled: at most one sample insert per $interval seconds, through Nginx into Tomcat."
        ;;
    off)
        systemctl disable --now contoso-orderdesk-traffic.service
        if systemctl is-active --quiet contoso-orderdesk-traffic.service; then
            echo 'Traffic unit is still active; stop was not verified.' >&2; exit 1
        fi
        echo 'HTTP traffic stopped. Tomcat, its SQL login and the Nginx proxy continue serving.'
        ;;
    *) echo 'Usage: sudo bash traffic.sh on [20..600] | off' >&2; exit 1 ;;
esac
