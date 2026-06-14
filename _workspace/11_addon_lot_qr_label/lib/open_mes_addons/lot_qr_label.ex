defmodule OpenMes.Addons.LotQrLabel do
  @moduledoc """
  애드온③ — LOT QR 라벨 생성 (LotQrLabel) 퍼사드/컨텍스트.

  설계 §2 애드온③: `MaterialLot` 의 `lot_no` 를 QR 코드 라벨(인쇄용)로 생성한다.

  ## 책임
    - 코어 `material_lots` 테이블을 **읽기 전용**으로 조회(단건/검색 목록).
    - LOT 데이터로 QR 페이로드(문자열)를 만들고 SVG QR 로 인코딩.
    - 인쇄용 라벨 데이터(lot_no, 품목, 수량, 상태, 생성일)를 조립.

  ## 읽기 전용 불변식(필수, 설계 §0-B-7 강조)
    - **MVP 는 읽기 전용으로 못 박는다.** 이 모듈은 Repo 읽기(all/one/get)만 호출한다.
    - LOT 상태(available → ...)를 **절대 바꾸지 않는다.** insert/update/delete 호출 0.
    - AuditLog/Outbox/LotConsumption 생성 0, 새 테이블 0 — 코어 도메인 트랜잭션을 만들지 않는다.

  ## 코어 비침투
    - 코어 스키마를 수정하지 않는다. 애드온 전용 읽기 스키마(`MaterialLot`)로 매핑만 한다.
    - `lib/open_mes_addons/lot_qr_label/` 에 격리. 코어 수정 0.

  ## config on/off
    - `config :open_mes, OpenMes.Addons.LotQrLabel, enabled: <bool>` 로 게이트.
  """

  import Ecto.Query, only: [from: 2]

  alias OpenMes.Addons.LotQrLabel.MaterialLot
  alias OpenMes.Repo

  @default_search_limit 50

  # ── config 게이트 ────────────────────────────────────────────────────

  @doc """
  애드온 활성 여부. `enabled?/0`(Extension behaviour) 가 위임하는 게이트.

  기본값 false — config 에서 명시적으로 켠다(설계 §2 공통 규칙).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :open_mes
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, false)
  end

  # ── 읽기 전용 조회 ────────────────────────────────────────────────────

  @doc """
  LOT 단건 조회(id 기준). 없으면 nil. **읽기 전용.**
  """
  @spec get_lot(binary()) :: MaterialLot.t() | nil | term()
  def get_lot(id) when is_binary(id), do: Repo.get(MaterialLot, id)

  @doc """
  lot_no 정확 일치로 LOT 단건 조회. 없으면 nil. **읽기 전용.**
  """
  @spec get_lot_by_no(String.t()) :: MaterialLot.t() | nil | term()
  def get_lot_by_no(lot_no) when is_binary(lot_no) do
    Repo.one(from l in MaterialLot, where: l.lot_no == ^lot_no)
  end

  @doc """
  LOT 검색 목록(라벨 선택용). **읽기 전용.**

  옵션:
    - `:q`      — lot_no 부분 일치(ILIKE). 빈 문자열/nil 이면 미적용.
    - `:status` — status 정확 일치 필터. nil 이면 미적용.
    - `:limit`  — 최대 행 수(기본 #{@default_search_limit}).

  최신 생성순(inserted_at desc)으로 정렬한다. 쓰기 0.
  """
  @spec search_lots(keyword()) :: [MaterialLot.t()]
  def search_lots(opts \\ []) do
    q = opts |> Keyword.get(:q) |> normalize_q()
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, @default_search_limit)

    MaterialLot
    |> filter_by_lot_no(q)
    |> filter_by_status(status)
    |> from_order_limit(limit)
    |> Repo.all()
  end

  defp normalize_q(nil), do: nil
  defp normalize_q(q) when is_binary(q) do
    case String.trim(q) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp filter_by_lot_no(query, nil), do: query

  defp filter_by_lot_no(query, q) do
    pattern = "%" <> escape_like(q) <> "%"
    from l in query, where: ilike(l.lot_no, ^pattern)
  end

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, ""), do: query

  defp filter_by_status(query, status) when is_binary(status),
    do: from(l in query, where: l.status == ^status)

  defp from_order_limit(query, limit) do
    from l in query, order_by: [desc: l.inserted_at], limit: ^limit
  end

  # ILIKE 메타문자(%, _, \) 이스케이프 — 사용자 입력이 와일드카드로 동작하지 않게.
  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ── 라벨 데이터 + QR ──────────────────────────────────────────────────

  @typedoc "인쇄용 라벨 데이터(LOT 읽기 결과 + QR 페이로드/SVG)."
  @type label :: %{
          lot_id: binary(),
          lot_no: String.t(),
          item_id: binary() | nil,
          lot_type: String.t() | nil,
          quantity: Decimal.t() | nil,
          status: String.t() | nil,
          status_label: String.t(),
          created_at: DateTime.t() | nil,
          qr_payload: String.t(),
          qr_svg: String.t()
        }

  @doc """
  MaterialLot(읽기 결과)로 인쇄용 라벨 데이터를 조립한다. **순수 변환(쓰기 0).**

  QR 페이로드는 `qr_payload/1`(아래)로 생성한 안정적 문자열이며,
  `qr_svg/1` 로 SVG 문자열을 만든다.
  """
  @spec build_label(MaterialLot.t()) :: label()
  def build_label(%MaterialLot{} = lot) do
    payload = qr_payload(lot)

    %{
      lot_id: lot.id,
      lot_no: lot.lot_no,
      item_id: lot.item_id,
      lot_type: lot.lot_type,
      quantity: lot.quantity,
      status: lot.status,
      status_label: MaterialLot.status_label(lot.status),
      created_at: lot.inserted_at,
      qr_payload: payload,
      qr_svg: qr_svg(payload)
    }
  end

  @doc """
  LOT QR 페이로드 문자열 생성. **순수 함수(테스트로 고정).**

  형식(MVP): `"OPENMES:LOT:<lot_no>"`.
  - 접두사 `OPENMES:LOT:` 로 스캐너/연동 시스템이 LOT 라벨임을 식별한다.
  - lot_no 만 담는다(상태/수량 같은 가변 값은 넣지 않는다 — 라벨 인쇄 후 LOT 상태가
    바뀌어도 QR 자체는 LOT 식별자로 항상 유효해야 하므로). 식별자만 인코딩한다.

  nil/빈 lot_no 는 빈 식별자로 처리(호출 측에서 LOT 존재를 보장).
  """
  @spec qr_payload(MaterialLot.t() | String.t() | nil) :: String.t()
  def qr_payload(%MaterialLot{lot_no: lot_no}), do: qr_payload(lot_no)
  def qr_payload(lot_no) when is_binary(lot_no), do: "OPENMES:LOT:" <> lot_no
  def qr_payload(nil), do: "OPENMES:LOT:"

  @doc """
  QR 페이로드 문자열을 SVG 문자열로 인코딩한다(경량 `eqrcode` 사용).

  `eqrcode` 는 순수 Elixir QR 생성기로 외부 바이너리/네트워크가 필요 없다.
  SVG 는 인쇄/미리보기에 그대로 임베드한다. 쓰기 0.

  `viewbox: true` 로 컨테이너 크기에 맞춰 스케일되도록 한다(라벨 레이아웃 친화).
  """
  @spec qr_svg(String.t()) :: String.t()
  def qr_svg(payload) when is_binary(payload) do
    payload
    |> EQRCode.encode()
    |> EQRCode.svg(width: 200, viewbox: true)
  end
end
