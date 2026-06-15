defmodule OpenMes.Media.Watch.Stability do
  @moduledoc """
  파일 쓰기 완료(안정화) 판정 — 순수 함수 모듈(파일시스템 의존 없음).

  설계 근거: `_workspace/05_architect_media_ingest_design.md` §2.3.

  쓰기 도중 파일을 잡으면 손상본을 수집한다. 아래 다중 게이트를 모두 통과해야 ":stable".
  Scanner 가 직전 스캔 관측치(prev)와 현재 관측치(curr)를 주입한다.

  게이트(통과 순서):
    1. 임시/숨김 이름 제외: .tmp/.part/.partial/.filepart/~ 끝 또는 . 시작 → :ignore
       (많은 쓰기 도구가 .tmp→rename 패턴. 최종 rename 후 이름만 잡는다.)
    2. mtime 유예(quiet period): now - mtime >= min_quiet_seconds(기본 10초)
       (쓰기 중이면 mtime 이 계속 갱신됨. 유예 동안 변화 없으면 쓰기 종료로 간주.)
    3. 최초 관측(prev=nil): 즉시 등록 금지 → :pending(:first_seen). 다음 스캔에 size 비교.
    4. size 안정화(2-스캔 비교): prev.size == curr.size 여야 함
       (rename 안 쓰고 직접 append 하는 도구 대비. 두 시점 size 동일 = 쓰기 멈춤.)

  핵심: `:first_seen` 은 절대 즉시 :stable 이 아니다. 최소 2회 스캔에 걸쳐
  size 불변 + mtime 유예를 확인한 뒤에만 :stable. 손상본 수집을 막는 1차 방어선.
  (콘텐츠 해시(§2.4)가 이관 단계 최종 방어선.)
  """

  @default_min_quiet_seconds 10

  # 임시/부분 쓰기 파일 접미사. 최종 rename 전 파일을 잡지 않기 위함.
  @temp_suffixes ~w(.tmp .part .partial .filepart ~)

  @type observation :: %{
          optional(:path) => String.t(),
          size: non_neg_integer(),
          mtime: DateTime.t()
        }

  @type result :: :stable | {:pending, atom()} | :ignore

  @doc """
  안정화 판정.

    * `prev` — 직전 스캔 관측치 `%{size, mtime}` 또는 nil(최초 관측)
    * `curr` — 현재 관측치 `%{path, size, mtime}`
    * `now`  — 현재 시각(DateTime). 테스트 주입 가능.
    * `opts` — `:min_quiet_seconds`(기본 10)

  반환: `:stable` | `{:pending, reason}` | `:ignore`
  """
  @spec assess(observation() | nil, observation(), DateTime.t(), keyword()) :: result()
  def assess(prev, curr, now, opts \\ []) do
    cond do
      temp_name?(Map.get(curr, :path, "")) ->
        :ignore

      not quiet_elapsed?(curr, now, opts) ->
        {:pending, :mtime_quiet}

      is_nil(prev) ->
        # 최초 관측 — 즉시 등록 금지. 다음 스캔에 size 비교를 위해 대기.
        {:pending, :first_seen}

      prev.size != curr.size ->
        {:pending, :size_changing}

      true ->
        :stable
    end
  end

  @doc """
  임시/숨김 파일명 여부. true 면 수집 대상에서 제외(:ignore).

  규칙:
    - @temp_suffixes 중 하나로 끝남(.tmp/.part/.partial/.filepart/~)
    - basename 이 . 으로 시작하는 숨김 파일(예: .DS_Store, .쓰는중)
  """
  def temp_name?(path) when is_binary(path) do
    base = Path.basename(path)

    String.starts_with?(base, ".") or
      Enum.any?(@temp_suffixes, fn suffix -> String.ends_with?(base, suffix) end)
  end

  def temp_name?(_), do: true

  @doc """
  mtime 유예 경과 여부. 마지막 수정 후 min_quiet_seconds 이상 지나야 true.
  쓰기가 진행 중이면 mtime 이 계속 갱신되어 유예가 경과하지 못한다.
  """
  def quiet_elapsed?(%{mtime: mtime}, now, opts) do
    min_quiet = Keyword.get(opts, :min_quiet_seconds, @default_min_quiet_seconds)
    DateTime.diff(now, mtime, :second) >= min_quiet
  end
end
