defmodule OpenMes.Addons.EquipmentOee do
  @moduledoc """
  애드온 ④ 설비 가동률 OEE 계산 — 컨텍스트 퍼사드(config 게이트).

  설계 `09_architect_registry_catalog_design.md` §2 애드온④, §7-b.

  ## 성격: 읽기 전용 분석 확장
    - `ProductionResult`(started_at/ended_at, good/defect_quantity), `Operation`,
      `Routing`(standard_cycle_time)을 Repo **읽기 쿼리**로만 집계한다.
    - OEE = 가용성(Availability) × 성능(Performance) × 품질(Quality).
    - 도메인 쓰기(생성/변경/삭제) 0, AuditLog 0, Outbox 0, **새 테이블 0**.
    - 코어 비침투: `lib/open_mes_addons/equipment_oee/` 격리, 코어 수정 0.

  ## 모듈 구성
    - `EquipmentOee`            (이 모듈) — on/off 게이트만.
    - `EquipmentOee.Calculator` — 순수 계산(테스트 용이, Repo 무관).
    - `EquipmentOee.Oee`        — 읽기 집계(Repo 읽기 → Calculator).
    - `EquipmentOee.ReadModels` — 코어 테이블 읽기 전용 투영 스키마.
    - `OpenMesWeb.Addons.EquipmentOeeLive` — 화면.
  """

  @doc """
  애드온 활성 여부. config 게이트.

      config :open_mes, OpenMes.Addons.EquipmentOee, enabled: true

  미설정 시 기본값은 `false`(코어 비침투 — 명시적으로 켜야 노출/라우트 등록).
  읽기 전용이라 켜져도 코어에 영향이 없다(EXT 컨벤션상 기본 off).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :open_mes
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, false)
  end
end
