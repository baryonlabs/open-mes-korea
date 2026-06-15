defmodule OpenMes.Extensions.Registry do
  @moduledoc """
  **(Deprecated 호환 shim)** `OpenMes.Extension.Registry`(계약 패키지)로 이전됨.

  구 네임스페이스 참조 호환을 위한 얇은 위임이다(설계 30 §6 M1, §7 S6). 새 코드는
  `OpenMes.Extension.Registry` 를 직접 쓴다.
  """

  defdelegate modules(), to: OpenMes.Extension.Registry
  defdelegate all(), to: OpenMes.Extension.Registry
  defdelegate enabled(), to: OpenMes.Extension.Registry
  defdelegate by_category(), to: OpenMes.Extension.Registry
end
