defmodule Mix.Tasks.Ext.VerifyTest do
  @moduledoc """
  `mix ext.verify` task 테스트 (설계 §7 T3).

    - 정상 확장(WoCsvExport)이 8/8 통과(종료코드 0, ✅ 리포트)
    - 콜백 누락 fixture → C1 ❌ + 종료코드 1
    - config 미등록 fixture → C3 ❌
    - 잘못된 category fixture → C6 ❌
    - 전체 스캔(인자 없음) 합계 라인 + 종료코드

  task 는 `Mix.Task.run("compile")` 만 호출(서버/Repo 미기동)하고, 위반 시
  `exit({:shutdown, 1})` 으로 종료코드를 낸다. 테스트는 IO 캡처 + 종료 catch 로 검증한다.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OpenMes.Test.ExtensionFixtures

  # ── 테스트 전용 fixture: 검증 실패 케이스 ────────────────────────────────

  # C1 실패용: 필수 콜백(version)을 일부러 빼고, behaviour 체크를 우회하기 위해
  # @behaviour 만 직접 선언(use Definition 대신). → category 는 유효하게 둔다.
  defmodule MissingCallback do
    @behaviour OpenMes.Extension
    def id, do: :fixture_missing_callback
    def name, do: "콜백 누락 확장"
    def description, do: "version/0 을 일부러 누락."
    def category, do: :analytics
    def enabled?, do: false
    def home_path, do: nil
    def icon, do: nil
    # version/0 누락 → C1 ❌
  end

  # C6 정보성 케이스: known_categories 에 없는 자유 카테고리(외부 확장의 자유 — 설계 30 §2.2).
  # 더 이상 C6 실패가 아니라 정보성(✅ + ℹ️)으로 통과한다.
  defmodule UnknownCategory do
    use OpenMes.Extension.Definition
    @impl true
    def id, do: :fixture_unknown_category
    @impl true
    def name, do: "미등록 카테고리 확장"
    @impl true
    def description, do: "known_categories/0 에 없는 자유 분류."
    @impl true
    def category, do: :not_a_real_category
    @impl true
    def version, do: "0.1.0"
    @impl true
    def enabled?, do: false
  end

  # C8 실패용: route_spec/0 형태가 잘못된 확장(routes 튜플 오류). 나머지는 정상.
  defmodule BadRouteSpec do
    use OpenMes.Extension.Definition
    @impl true
    def id, do: :fixture_bad_route_spec
    @impl true
    def name, do: "잘못된 라우트 스펙 확장"
    @impl true
    def description, do: "route_spec/0 routes 튜플이 형태 오류."
    @impl true
    def category, do: :analytics
    @impl true
    def version, do: "0.1.0"
    @impl true
    def enabled?, do: false
    # routes 튜플의 verb 가 잘못됨(:foo) → C8 ❌
    @impl true
    def route_spec, do: %{scope: "/x", pipeline: :browser, routes: [{:foo, "/y", SomeMod, :index}]}
  end

  # task 실행 + IO 캡처 + 종료코드 판정을 한 번에.
  # 반환: {output, exit_code}  (통과 0 / 위반 1)
  defp run_verify(args) do
    code_ref = make_ref()
    parent = self()

    output =
      capture_io(fn ->
        result =
          try do
            Mix.Tasks.Ext.Verify.run(args)
            0
          catch
            :exit, {:shutdown, c} -> c
          end

        send(parent, {code_ref, result})
      end)

    code =
      receive do
        {^code_ref, c} -> c
      after
        0 -> raise "verify 실행 결과 미수신"
      end

    {output, code}
  end

  describe "정상 확장" do
    test "WoCsvExport 가 8/8 통과(종료코드 0)" do
      {out, code} = run_verify(["OpenMes.Addons.WoCsvExport.Extension"])

      assert code == 0
      assert out =~ "ext.verify: OpenMes.Addons.WoCsvExport.Extension"
      assert out =~ "✅ C1"
      assert out =~ "✅ C7"
      assert out =~ "8/8 통과 ✅"
      refute out =~ "❌"
    end

    test "미등록 카테고리(자유 atom)는 C6 정보성으로 통과(종료코드 0)" do
      # 원본 :extensions 를 복원해야 다른 테스트(WoCsvExport 단건 C3)와 상태 누수 없음.
      original = Application.get_env(:open_mes, :extensions)
      Application.put_env(:open_mes, :extensions, [UnknownCategory])

      on_exit(fn ->
        if original do
          Application.put_env(:open_mes, :extensions, original)
        else
          Application.delete_env(:open_mes, :extensions)
        end
      end)

      {out, code} = run_verify(["#{inspect(UnknownCategory)}"])

      assert code == 0
      assert out =~ "✅ C6"
      assert out =~ "미등록 카테고리"
      refute out =~ "❌ C6"
    end
  end

  describe "실패 케이스 (종료코드 1)" do
    setup do
      original = Application.get_env(:open_mes, :extensions)

      on_exit(fn ->
        if original do
          Application.put_env(:open_mes, :extensions, original)
        else
          Application.delete_env(:open_mes, :extensions)
        end
      end)

      :ok
    end

    test "필수 콜백 누락 → C1 ❌ + 종료코드 1" do
      # 등록은 해 둬야 C3 가 통과되어 C1 실패가 부각된다.
      Application.put_env(:open_mes, :extensions, [MissingCallback])

      {out, code} = run_verify(["#{inspect(MissingCallback)}"])

      assert code == 1
      assert out =~ "❌ C1"
      assert out =~ "version"
      assert out =~ "종료코드 1"
    end

    test "config :extensions 미등록 → C3 ❌" do
      # UnknownCategory 를 등록 목록에서 제외 → C3 미등록.
      Application.put_env(:open_mes, :extensions, ExtensionFixtures.all_fixtures())

      {out, code} = run_verify(["#{inspect(UnknownCategory)}"])

      assert code == 1
      assert out =~ "❌ C3"
      assert out =~ "config :open_mes, :extensions"
    end

    test "존재하지 않는 모듈 → C0 모듈 로드 ❌" do
      {out, code} = run_verify(["OpenMes.Addons.NoSuchExtension"])

      assert code == 1
      assert out =~ "❌ C0"
    end

    test "잘못된 route_spec 형태 → C8 ❌" do
      Application.put_env(:open_mes, :extensions, [BadRouteSpec])

      {out, code} = run_verify(["#{inspect(BadRouteSpec)}"])

      assert code == 1
      assert out =~ "❌ C8"
      assert out =~ "route_spec 형태 오류"
    end
  end

  describe "전체 스캔 (인자 없음)" do
    test "등록된 확장 전부 통과, 합계 라인 + 종료코드 0" do
      {out, code} = run_verify([])

      registered = length(Application.get_env(:open_mes, :extensions, []))

      assert code == 0
      assert out =~ "전체 스캔"
      assert out =~ "#{registered}/#{registered} 확장 통과 ✅"
    end
  end
end
