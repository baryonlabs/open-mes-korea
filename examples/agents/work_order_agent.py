#!/usr/bin/env python3
"""Open MES Korea — 작업지시 에이전트 예시.

이 스크립트는 "각자 agent 를 API 로 구축해 MES 를 직접 조정한다"는 방식을 보여준다.
외부 의존성 없음(파이썬 표준 라이브러리만). 누구나 이 파일을 복제해 자기 규칙의 에이전트를
만들 수 있다 — 조회는 자유, **모든 쓰기는 `X-Actor-Id` 헤더가 강제**되어 그 actor 이름으로
AuditLog 에 남는다. 즉 사람이든 에이전트든 "누가 무엇을 바꿨는지"가 단일 진실 공급원(SSOT)에
그대로 축적된다.

SSOT 원칙(요약):
  - 읽기: GET /api/work_orders — actor 불필요.
  - 쓰기: POST .../{release,start,complete,cancel} — X-Actor-Id 필수.
          MES 가 상태 전이 + AuditLog(before/after) + Event Outbox 를 한 트랜잭션에 기록.
  - 따라서 에이전트를 아무리 많이 붙여도, 진실(상태·이력·감사)은 MES DB 한 곳에 모인다.

사용:
  BASE_URL=https://openmes-demo.fly.dev ACTOR=agent-release-bot python3 work_order_agent.py
  (기본 BASE_URL=http://localhost:4002, ACTOR=agent-demo)

이 예시 에이전트의 정책(자유롭게 수정하세요):
  "draft 상태의 작업지시를 찾아 released 로 올린다(생산 착수 준비)."
"""
import json
import os
import urllib.error
import urllib.request

BASE_URL = os.environ.get("BASE_URL", "http://localhost:4002").rstrip("/")
ACTOR = os.environ.get("ACTOR", "agent-demo")


def _request(method, path, actor=None):
    url = f"{BASE_URL}{path}"
    headers = {"Accept": "application/json"}
    if actor:
        # 쓰기에는 actor 가 필수 — 이 값이 AuditLog 의 actor_id 가 된다.
        headers["X-Actor-Id"] = actor
    req = urllib.request.Request(url, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8")
            return resp.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8")
        return e.code, (json.loads(body) if body else None)


def list_work_orders():
    """읽기 — actor 없이 조회."""
    status, data = _request("GET", "/api/work_orders")
    if status != 200:
        raise SystemExit(f"작업지시 조회 실패: HTTP {status}")
    return data["data"]


def release(work_order_id, actor):
    """쓰기 — actor 를 붙여 상태 전이(감사 대상)."""
    return _request("POST", f"/api/work_orders/{work_order_id}/release", actor=actor)


def main():
    print(f"MES: {BASE_URL}  ·  agent actor: {ACTOR}\n")

    work_orders = list_work_orders()
    print(f"작업지시 {len(work_orders)}건:")
    for w in work_orders:
        print(f"  - {w['work_order_no']:<12} {w['status']}")

    # 정책: draft 를 찾아 released 로 올린다.
    draft = next((w for w in work_orders if w["status"] == "draft"), None)
    if not draft:
        print("\n[에이전트] draft 상태 작업지시가 없어 조정할 대상이 없습니다.")
        return

    print(f"\n[에이전트] draft '{draft['work_order_no']}' 를 released 로 전이합니다…")

    # 1) actor 없이 시도하면 거부됨(감사 강제 증명)
    status_no_actor, _ = _request("POST", f"/api/work_orders/{draft['id']}/release")
    print(f"  actor 없이 요청 → HTTP {status_no_actor} (거부: 쓰기에는 X-Actor-Id 필수)")

    # 2) actor 를 붙여 실제 조정
    status, data = release(draft["id"], ACTOR)
    if status == 200:
        print(f"  actor='{ACTOR}' 로 요청 → HTTP 200, 새 상태: {data['data']['status']}")
        print(
            f"\n[SSOT] 이 전이는 MES AuditLog 에 actor_id='{ACTOR}', action='work_order.release' 로"
            f"\n       before/after 와 함께 기록되었습니다. /admin/system/audit-log 에서 확인하세요."
        )
    else:
        print(f"  전이 실패 → HTTP {status}: {data}")


if __name__ == "__main__":
    main()
