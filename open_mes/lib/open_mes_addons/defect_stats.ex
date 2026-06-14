defmodule OpenMes.Addons.DefectStats do
  @moduledoc """
  애드온 ② 불량 통계 위젯 — 컨텍스트 퍼사드(config 게이트).

  설계 `09_architect_registry_catalog_design.md` §2 애드온②.

  이 애드온은 **읽기 전용**이다:
    - `DefectRecord`(defect_code, quantity), `ProductionResult`(good/defect_quantity)를
      Repo 읽기 쿼리로만 집계한다.
    - 도메인 쓰기(생성/변경/삭제) 0, AuditLog 0, Outbox 0, 새 테이블 0.
    - 코어 스키마(`OpenMes.Production.*`)를 변경하지 않는다(읽기로 alias 만 허용 — 설계 §2 결정).

  이 모듈은 on/off 게이트(`enabled?/0`)만 제공한다. 실제 집계는
  `OpenMes.Addons.DefectStats.Stats`, 화면은 `OpenMesWeb.Addons.DefectStatsLive` 가 담당한다.
  """

  @doc """
  애드온 활성 여부. config 게이트.

      config :open_mes, OpenMes.Addons.DefectStats, enabled: true

  미설정 시 기본값은 `false`(코어 비침투 — 명시적으로 켜야 노출/라우트 등록).
  읽기 전용이라 켜져도 코어에 영향이 없다(기본 on 도 안전하나, EXT 컨벤션상 기본 off).
  """
  def enabled? do
    :open_mes
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, false)
  end
end
