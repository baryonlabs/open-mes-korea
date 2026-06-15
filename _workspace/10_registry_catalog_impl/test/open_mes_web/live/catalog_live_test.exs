defmodule OpenMesWeb.CatalogLiveTest do
  @moduledoc """
  카탈로그 LiveView 테스트 (설계 §7.a).

    - mount → 등록 확장 수만큼 카드 렌더
    - 활성/비활성 배지 구분
    - 화면 있고 활성인 확장만 '열기' 링크
    - 카테고리 필터(phx-click) → visible 갱신
    - 모든 확장 비활성 회귀: 비활성 카드만으로 정상 렌더

  config :extensions 를 픽스처로 임시 주입해, 실제 확장 통합 여부와 무관하게 검증한다.
  """
  use OpenMesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenMes.Test.ExtensionFixtures

  setup do
    original = Application.get_env(:open_mes, :extensions)
    Application.put_env(:open_mes, :extensions, ExtensionFixtures.all_fixtures())

    on_exit(fn ->
      if original do
        Application.put_env(:open_mes, :extensions, original)
      else
        Application.delete_env(:open_mes, :extensions)
      end
    end)

    :ok
  end

  describe "mount/render" do
    test "등록 확장이 모두 카드로 렌더된다(비활성 포함)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "활성 화면 확장"
      assert html =~ "활성 무화면 확장"
      assert html =~ "비활성 화면 확장"
      assert html =~ "예외 확장"
    end

    test "활성/비활성 배지가 표시된다", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "활성"
      assert html =~ "비활성"
    end

    test "활성+화면 확장에만 '열기' 링크가 있다", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # 활성+화면 → 링크 노출
      assert html =~ "/extensions/fixture-enabled-screen"
      # 비활성+화면 → 링크 미노출(비활성이므로)
      refute html =~ "/extensions/fixture-disabled-screen"
    end

    test "/extensions 별칭도 동일 카탈로그를 렌더", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/extensions")
      assert html =~ "확장 카탈로그"
      assert html =~ "활성 화면 확장"
    end
  end

  describe "카테고리 필터" do
    test "특정 카테고리 클릭 시 해당 카드만 보인다", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> element("button[phx-value-category='production']")
        |> render_click()

      assert html =~ "활성 화면 확장"
      refute html =~ "활성 무화면 확장"
      refute html =~ "비활성 화면 확장"
    end

    test "전체 버튼으로 복원", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button[phx-value-category='quality']")
      |> render_click()

      html =
        view
        |> element("button[phx-value-category='all']")
        |> render_click()

      assert html =~ "활성 화면 확장"
      assert html =~ "비활성 화면 확장"
    end
  end

  describe "전체 비활성 회귀" do
    test "모든 확장이 비활성이어도 카탈로그가 정상 렌더된다", %{conn: conn} do
      Application.put_env(:open_mes, :extensions, [ExtensionFixtures.DisabledWithScreen])

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "비활성 화면 확장"
      assert html =~ "비활성"
      # 비활성이므로 열기 링크 없음
      refute html =~ "/extensions/fixture-disabled-screen"
    end

    test "등록 확장이 0개여도 카탈로그가 죽지 않는다", %{conn: conn} do
      Application.put_env(:open_mes, :extensions, [])
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "확장 카탈로그"
    end
  end
end
