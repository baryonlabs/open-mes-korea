defmodule OpenMes.Test.ExtensionFixtures do
  @moduledoc """
  레지스트리/카탈로그 테스트용 가짜 확장 모듈.

  실제 확장(EXT-1/EXT-2/애드온)에 의존하지 않고 레지스트리 동작을 검증하기 위해,
  `OpenMes.Extensions.Extension` behaviour 를 구현한 최소 더미들을 둔다.
  config `:extensions` 에 이 모듈들을 임시 주입하여 테스트한다.
  """

  defmodule EnabledWithScreen do
    @moduledoc "활성 + 화면 있음. 카드에 '열기' 링크가 나와야 함."
    use OpenMes.Extensions.Definition

    @impl true
    def id, do: :fixture_enabled_screen
    @impl true
    def name, do: "활성 화면 확장"
    @impl true
    def description, do: "활성이며 자체 화면을 가진 더미 확장."
    @impl true
    def category, do: :production
    @impl true
    def version, do: "1.0.0"
    @impl true
    def enabled?, do: true
    @impl true
    def home_path, do: "/extensions/fixture-enabled-screen"
  end

  defmodule EnabledNoScreen do
    @moduledoc "활성 + 화면 없음. '열기' 링크가 없어야 함."
    use OpenMes.Extensions.Definition

    @impl true
    def id, do: :fixture_enabled_noscreen
    @impl true
    def name, do: "활성 무화면 확장"
    @impl true
    def description, do: "활성이지만 자체 화면이 없는 더미 확장."
    @impl true
    def category, do: :ingest
    @impl true
    def version, do: "0.2.0"
    @impl true
    def enabled?, do: true
    # home_path 기본값 nil 유지(override 안 함).
  end

  defmodule DisabledWithScreen do
    @moduledoc "비활성 + 화면 있음. 비활성이므로 '열기' 링크가 없어야 함('비활성' 배지)."
    use OpenMes.Extensions.Definition

    @impl true
    def id, do: :fixture_disabled_screen
    @impl true
    def name, do: "비활성 화면 확장"
    @impl true
    def description, do: "화면은 있으나 비활성인 더미 확장."
    @impl true
    def category, do: :quality
    @impl true
    def version, do: "0.1.0"
    @impl true
    def enabled?, do: false
    @impl true
    def home_path, do: "/extensions/fixture-disabled-screen"
  end

  defmodule Raising do
    @moduledoc "enabled?/0 가 raise. 레지스트리 safe_enabled? 견고성 검증용(설계 §1.3)."
    use OpenMes.Extensions.Definition

    @impl true
    def id, do: :fixture_raising
    @impl true
    def name, do: "예외 확장"
    @impl true
    def description, do: "enabled? 가 raise 하는 더미 확장."
    @impl true
    def category, do: :analytics
    @impl true
    def version, do: "0.0.1"
    @impl true
    def enabled?, do: raise("config 미설정 시뮬레이션")
  end

  @doc "config :extensions 에 주입할 표준 픽스처 목록."
  def all_fixtures,
    do: [EnabledWithScreen, EnabledNoScreen, DisabledWithScreen, Raising]
end
