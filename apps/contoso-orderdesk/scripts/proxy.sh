#!/bin/bash
# Run only on OnPrem-Linux-Web. Never touch its default port-80 site.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
[[ $EUID == 0 ]] || { echo 'Run with sudo on OnPrem-Linux-Web.' >&2; exit 1; }
exec 9>/var/lock/contoso-orderdesk-proxy.lock
flock -n 9 || { echo 'Another proxy operation is running.' >&2; exit 1; }
BACKUP=/var/backups/contoso-orderdesk-proxy
FILE=/etc/nginx/conf.d/lab-order-desk.conf
case "${1:-}" in
    install)
        command -v nginx >/dev/null
        nginx -t
        python3 - "$FILE" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
original = '''server {
    listen 8080;
    server_name _;
    location /api/ {
        proxy_pass http://onprem-app:3000/api/;
        proxy_set_header Host $host;
        proxy_connect_timeout 5s;
    }
    location / {
        return 200 'TD SYNNEX order desk proxy. Try /api/health\\n';
        add_header Content-Type text/plain;
    }
}'''
managed = '# Contoso Order Desk managed lab proxy'
if p.exists():
    text = p.read_text()
    if not text.startswith(managed + '\n') and ''.join(text.split()) != ''.join(original.split()):
        raise SystemExit('Existing 8080 configuration is not the known lab proxy; refusing to overwrite a non-lab app.')
if p.is_symlink():
    raise SystemExit('Refusing a symlinked proxy configuration; review manually.')
PY
        python3 "$HERE/snapshot.py" save "$BACKUP" --proxy
        python3 "$HERE/hosts.py"
        cat > "$FILE" <<'NGINX'
# Contoso Order Desk managed lab proxy
server {
    listen 8080;
    server_name _;
    location /api/ {
        proxy_pass http://onprem-app:3000/api/;
        proxy_set_header Host $http_host;
        proxy_connect_timeout 5s;
        proxy_read_timeout 20s;
    }
    location / {
        proxy_pass http://onprem-app:3000/;
        proxy_set_header Host $http_host;
        proxy_connect_timeout 5s;
        proxy_read_timeout 20s;
    }
}
NGINX
        if ! nginx -t; then
            python3 "$HERE/snapshot.py" restore-files "$BACKUP"
            nginx -t
            echo 'Proxy test failed; original files restored. No reload was performed.' >&2
            exit 1
        fi
        systemctl reload nginx
        echo '8080 forwards the desk and API. Port 80 is untouched; validate after Tomcat cutover.'
        ;;
    rollback)
        [[ ${2:-} == --restore-original ]] || { echo 'Use proxy.sh rollback --restore-original after reviewing /etc/hosts backup.' >&2; exit 1; }
        python3 "$HERE/snapshot.py" restore-files "$BACKUP"
        nginx -t
        systemctl reload nginx
        echo 'Original proxy file and Linux-Web hosts file restored. Snapshot retained.'
        ;;
    repoint)
        [[ $# == 4 ]] || { echo 'Usage: proxy.sh repoint <SQL-IP> <App-IP> <Nginx-IP>' >&2; exit 1; }
        [[ -f $BACKUP/complete ]] || { echo 'No managed proxy snapshot; review first.' >&2; exit 1; }
        python3 "$HERE/hosts.py" --sql "$2" --app "$3" --nginx "$4"
        nginx -t
        systemctl reload nginx
        echo 'Guest aliases updated and Nginx reloaded to resolve the new App address.'
        ;;
    *) echo 'Usage: sudo bash proxy.sh install | rollback --restore-original | repoint <SQL-IP> <App-IP> <Nginx-IP>' >&2; exit 1 ;;
esac
