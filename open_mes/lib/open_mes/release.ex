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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
