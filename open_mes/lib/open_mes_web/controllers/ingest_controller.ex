defmodule OpenMesWeb.IngestController do
  @moduledoc """
  설비 텔레메트리 수집 HTTP 엔드포인트. 설계 §4.

  POST /ingest/equipment : 단건 객체 또는 객체 배열 수신.
    - 토큰 검증(RequireDeviceToken plug) 후 Ingest.push 로 버퍼 적재 → **즉시 202**.
    - 적재/검증 결과는 기다리지 않는다(고처리량 핵심, 설계 §4.1 202 비동기).
    - 큐 상한 초과(백프레셔) → 429.

  GET /ingest/health : 파이프라인 활성/큐 깊이 확인.

  컨트롤러는 얇게 유지한다 — 비즈니스 로직은 OpenMes.Ingest 퍼사드가 담당.
  """
  use OpenMesWeb, :controller

  alias OpenMes.Ingest

  # 본 컨트롤러의 모든 액션은 conn 을 직접 반환한다(에러 튜플 없음).
  # 따라서 action_fallback 은 사용하지 않는다.

  @doc "단건/배열 측정값 수집. 즉시 202(또는 큐 포화 시 429)."
  def create(conn, params) do
    payloads = normalize_payloads(params)

    case Ingest.push_many(payloads) do
      # 전부 적재 성공 → 202
      {accepted, 0} ->
        conn
        |> put_status(:accepted)
        |> json(%{accepted: accepted})

      # 하나라도 큐 포화로 거부됨 → 429 백프레셔(디바이스 재전송 유도, 설계 §3.4)
      {accepted, rejected} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{
          error: "ingest_busy",
          message: "수집 큐가 포화 상태입니다. 잠시 후 재전송하세요.",
          accepted: accepted,
          rejected: rejected,
          retry_after_ms: 500
        })
    end
  end

  @doc "파이프라인 헬스 체크: 활성 여부 + 큐 깊이."
  def health(conn, _params) do
    json(conn, %{
      enabled: Ingest.enabled?(),
      queue_depth: Ingest.queue_depth()
    })
  end

  # body 가 단건 객체면 [객체], 배열이면 그대로. Phoenix 는 최상위 JSON 배열을
  # params["_json"] 에 담는다.
  defp normalize_payloads(%{"_json" => list}) when is_list(list), do: list
  defp normalize_payloads(params) when is_map(params), do: [params]
  defp normalize_payloads(_), do: []
end
