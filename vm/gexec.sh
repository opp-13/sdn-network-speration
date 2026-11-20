#!/usr/bin/env bash
# 단말 VM 안에서 명령 실행 — 네트워크를 거치지 않는 QEMU 게스트 에이전트 사용 (원칙 3 유지)
# 사용: sudo vm/gexec.sh <VM> '<셸 명령>' [타임아웃초(기본 60)]
# 표준출력·표준에러를 그대로 출력하고, 명령의 종료 코드로 끝난다.
set -euo pipefail
vm=${1:?VM}; cmd=${2:?명령}; to=${3:-60}
exec python3 - "$vm" "$cmd" "$to" <<'PY'
import json, subprocess, sys, time, base64
vm, cmd, to = sys.argv[1], sys.argv[2], int(sys.argv[3])
def qga(obj):
    r = subprocess.run(["virsh", "qemu-agent-command", vm, json.dumps(obj), "--timeout", "10"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(f"게스트 에이전트 오류({vm}): {r.stderr.strip()}\n"); sys.exit(125)
    return json.loads(r.stdout)["return"]
pid = qga({"execute": "guest-exec", "arguments": {
    "path": "/bin/sh", "arg": ["-c", cmd], "capture-output": True}})["pid"]
end = time.time() + to
while True:
    st = qga({"execute": "guest-exec-status", "arguments": {"pid": pid}})
    if st.get("exited"):
        break
    if time.time() > end:
        sys.stderr.write(f"시간 초과 {to}s: {cmd}\n"); sys.exit(124)
    time.sleep(0.3)
for k, f in (("out-data", sys.stdout), ("err-data", sys.stderr)):
    if k in st:
        f.write(base64.b64decode(st[k]).decode(errors="replace"))
sys.exit(st.get("exitcode", 0))
PY
