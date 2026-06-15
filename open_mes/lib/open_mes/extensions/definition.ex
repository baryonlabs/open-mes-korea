defmodule OpenMes.Extensions.Definition do
  @moduledoc """
  **(Deprecated 호환 shim)** `OpenMes.Extension.Definition`(계약 패키지)로 이전됨.

  `use OpenMes.Extensions.Definition` 는 새 매크로 `use OpenMes.Extension.Definition` 로
  그대로 위임된다(설계 30 §6 M1). 새 코드는 새 네임스페이스를 직접 쓴다.
  """
  defmacro __using__(opts) do
    quote do
      use OpenMes.Extension.Definition, unquote(opts)
    end
  end
end
