defmodule OpenMes.Extensions.Extension do
  @moduledoc """
  **(Deprecated 호환 shim)** `OpenMes.Extension`(계약 패키지 `open_mes_extension_api`)로 이전됨.

  확장 시스템은 별도 repo 확장이 코어 소스 0 수정으로 붙도록 계약 패키지로 추출되었다
  (설계 30 §3). 새 코드는 `OpenMes.Extension` / `OpenMes.Extension.Definition` /
  `OpenMes.Extension.Registry` 를 직접 쓴다. 이 모듈은 구 네임스페이스 참조 호환을 위한
  얇은 위임이며, 다음 버전에서 제거한다(설계 30 §6 M1, §7 S6).
  """

  @deprecated "OpenMes.Extension 을 사용하세요(계약 패키지 open_mes_extension_api)."
  defdelegate known_categories(), to: OpenMes.Extension

  @doc deprecated: "known_categories/0 를 사용하세요."
  @spec categories() :: [atom()]
  def categories, do: OpenMes.Extension.known_categories()
end
