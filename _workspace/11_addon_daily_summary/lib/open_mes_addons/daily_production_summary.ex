defmodule OpenMes.Addons.DailyProductionSummary do
  @moduledoc """
  애드온 ⑤ 일일 생산 요약 — 컨텍스트 퍼사드(공개 진입점 + config 게이트).

  설계 `09_architect_registry_catalog_design.md` §2 애드온⑤.

  ## 목적

  특정 날짜의 생산 현황을 한 장으로 요약한다:
    - 작업지시 상태별 건수(완료/진행중/...) 와 가동(in_progress) 작업지시 수
    - 해당일에 종료(`ProductionResult.ended_at`)된 실적 기준 총 양품/불량 수량
    - 품목별 양품/불량 합산(상위 N)

  ## 성격(읽기 전용 — 코어 비침투)

    - **읽기 전용**: 코어 데이터(`WorkOrder`, `ProductionResult`, `Item`)를 Repo 읽기
      쿼리로만 집계한다. 쓰기/DELETE/AuditLog/Outbox 0, 새 DB 테이블 0개.
    - **코어 비침투**: 코어 파일을 수정하지 않는다. WorkOrder 는 공개 조회 함수
      (`OpenMes.Production.list_work_orders/1`)로, ProductionResult/Item 은 애드온
      전용 **읽기 전용 스키마**(`Schemas`)로 읽는다(설계 §2 결정 — 읽기는 침투 아님).
    - config on/off 게이트. 읽기 전용이라 켜져도 코어에 영향 없음(EXT 컨벤션상 기본 off).

  이 모듈은 게이트(`enabled?/0`)와 요약 위임만 담당한다. 실제 집계는
  `OpenMes.Addons.DailyProductionSummary.Summary`, 화면은
  `OpenMesWeb.Addons.DailyProductionSummaryLive`, behaviour 메타데이터는
  `*.Extension` 이 담당한다.
  """

  alias OpenMes.Addons.DailyProductionSummary.Summary

  @doc """
  애드온 활성 여부(config 게이트).

      config :open_mes, OpenMes.Addons.DailyProductionSummary, enabled: true

  값이 없으면 기본 `false`(비활성). `*.Extension.enabled?/0` 가 이 함수에 위임한다.
  명시적으로 켜야 카탈로그 라우트가 등록된다(코어 비침투 — 기본 off).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :open_mes
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, false)
    |> case do
      true -> true
      _ -> false
    end
  end

  @doc """
  선택한 날짜(`Date`)의 생산 요약을 만든다.

  `opts`:
    - `:time_zone` — 날짜 경계 계산에 쓸 타임존(기본 `"Etc/UTC"`).
      선택일 00:00:00 ~ 다음날 00:00:00(해당 타임존)을 UTC 로 변환해 `ended_at` 필터에 쓴다.
    - `:top_n` — 품목별 생산량 상위 표시 개수(기본 10).

  반환은 `t:OpenMes.Addons.DailyProductionSummary.Summary.t/0` 맵이다.
  데이터가 없는 날도 빈 요약으로 안전하게 반환한다(절대 raise 하지 않음).
  """
  @spec summarize(Date.t(), keyword()) :: Summary.t()
  defdelegate summarize(date, opts \\ []), to: Summary
end
