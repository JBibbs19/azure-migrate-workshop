#!/bin/bash
set -euo pipefail
unit=contoso-employee-orders.service
worker=/opt/contoso-employee-orders/employee-orders.py
healthy() {
    test "$(systemctl show "$unit" --property=LoadState --value)" = loaded &&
    test "$(systemctl show "$unit" --property=ActiveState --value)" = active &&
    test "$(systemctl show "$unit" --property=SubState --value)" = running &&
    test "$(systemctl show "$unit" --property=UnitFileState --value)" = enabled || return 1
    pid=$(systemctl show "$unit" --property=MainPID --value)
    test "$pid" -gt 0 && kill -0 "$pid" || return 1
    EMPLOYEE_EXPECTED_PID="$pid" python3 -B "$worker" --status
}
case "${1:-}" in
    start)
        # Daytime-only read contracts; do not require employee browsing/writes overnight.
        python3 -B - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location('employee_orders', '/opt/contoso-employee-orders/employee-orders.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
client = module.Client()
if module.daytime(module.now_utc()):
    module.order_page(client.request('/api/orders', params={'pageSize': module.PAGE_SIZE}))
if module.daytime(module.now_utc()):
    module.options(client.request('/api/order-options'))
PY
        systemctl enable --now "$unit"
        for attempt in {1..10}; do
            if healthy; then echo LAB_EMPLOYEE_ORDERS_READY; exit 0; fi
            sleep 1
        done
        echo 'Employee-order startup unverified; inspect Status/Stop before another Start.' >&2
        exit 1
        ;;
    status)
        systemctl show "$unit" --property=LoadState,ActiveState,SubState,UnitFileState,MainPID
        healthy
        echo LAB_EMPLOYEE_ORDERS_RUNNING
        ;;
    stop)
        systemctl disable --now "$unit"
        test "$(systemctl show "$unit" --property=ActiveState --value)" = inactive
        test "$(systemctl show "$unit" --property=UnitFileState --value)" = disabled
        echo LAB_EMPLOYEE_ORDERS_STOPPED
        ;;
    *) echo 'Usage: control.sh start | status | stop' >&2; exit 2 ;;
esac
