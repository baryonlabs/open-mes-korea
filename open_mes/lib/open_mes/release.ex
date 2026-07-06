defmodule OpenMes.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :open_mes

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  데모 시드 1회 실행(릴리스 환경, Mix 없음).

  `bin/open_mes eval 'OpenMes.Release.seed()'` 로 호출. 전체 앱을 기동해(Endpoint 는
  PHX_SERVER 미설정이라 non-serving) Repo·PubSub·Outbox 가 살아있는 상태에서 seeds.exs 를
  평가한다. seeds.exs 는 멱등이 아니므로 최초 1회만 실행할 것.
  """
  def seed do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)
    path = Application.app_dir(@app, "priv/repo/seeds.exs")

    if File.exists?(path) do
      Code.eval_file(path)
    else
      raise "seeds.exs 를 찾을 수 없습니다: #{path}"
    end
  end

  @doc """
  데모 초기화: 도메인 데이터 전부 삭제 후 시드 재적재(공개 데모용).

  인증 없는 공개 데모라 누구나 추가/삭제한다. 정기적으로(예: fly 스케줄 머신 하루 1회)
  이 함수를 실행해 깨끗한 시드 상태로 되돌린다. `schema_migrations` 는 보존한다.

  `bin/open_mes eval 'OpenMes.Release.reset_demo()'` (PHX_SERVER 언셋 권장 — non-serving).
  """
  def reset_demo do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)
    repo = List.first(repos())

    {:ok, %{rows: rows}} =
      repo.query(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations'"
      )

    tables = rows |> List.flatten() |> Enum.map_join(", ", &~s("#{&1}"))

    if tables != "" do
      repo.query!("TRUNCATE TABLE #{tables} RESTART IDENTITY CASCADE")
    end

    path = Application.app_dir(@app, "priv/repo/seeds.exs")
    if File.exists?(path), do: Code.eval_file(path)
    IO.puts("[reset_demo] 도메인 데이터 초기화 + 시드 재적재 완료")
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
