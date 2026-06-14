defmodule OpenMesWeb.GuideLive do
  @moduledoc """
  확장 개발 가이드(/extensions/guide) — 앱 내 자기완결 페이지.

  `docs/extension-development.md` 의 내용을 admin_shell 스타일로 렌더한다. 외부 GitHub URL
  의존 없이 앱 안에서 가이드를 보여주므로 카탈로그에서 바로 진입할 수 있다.

  데이터 소스 없음 — 정적 표시뿐(도메인 쓰기/AuditLog/Outbox 무관). 카탈로그와 동일하게
  `OpenMesWeb.Admin.AdminLive` 베이스를 use 하여 공통 레이아웃을 공유한다(라우트 /extensions/guide,
  인가상 system_admin 영역). 최소 확장 예제 코드는 `@sample_extension` 모듈 속성에 인라인한다(pi).
  """
  use OpenMesWeb.Admin.AdminLive

  # 가이드 본문 §3 의 "최소 확장 만들기" 코드 예제(pre 블록에 그대로 표시).
  @sample_extension """
  defmodule OpenMes.Addons.MyReport.Extension do
    use OpenMes.Extensions.Definition

    @impl true
    def id, do: :addon_my_report
    @impl true
    def name, do: "우리 회사 일일 리포트"
    @impl true
    def description, do: "현장 요구에 맞춘 일일 생산 리포트를 조회한다(읽기 전용)."
    @impl true
    def category, do: :analytics
    @impl true
    def version, do: "0.1.0"
    @impl true
    def enabled?, do: OpenMes.Addons.MyReport.enabled?()

    # 자체 화면이 있으면 home_path 를 override.
    @impl true
    def home_path, do: "/extensions/my-report"
  end
  """

  @sample_config """
  # config/config.exs
  config :open_mes, :extensions, [
    # ... 기존 확장들 ...
    OpenMes.Addons.MyReport.Extension   # ← 우리 확장 추가
  ]

  config :open_mes, OpenMes.Addons.MyReport, enabled: true
  """

  # 필수/선택 콜백 요약(SDK 레퍼런스). {콜백, 타입, 설명}.
  @required_callbacks [
    {"id/0", "atom()", "확장 고유 식별자(영문 atom, 안정적)"},
    {"name/0", "String.t()", "사람이 읽는 이름(한국어)"},
    {"description/0", "String.t()", "한 줄 설명(한국어)"},
    {"category/0", "category()", "분류 atom(카탈로그 필터)"},
    {"version/0", "String.t()", "버전 문자열"},
    {"enabled?/0", "boolean()", "활성 여부(config 게이트)"}
  ]

  @optional_callbacks_doc [
    {"home_path/0", "String.t() | nil", "자체 화면 경로(없으면 nil)"},
    {"icon/0", "String.t() | nil", "카탈로그 카드 아이콘(없으면 nil)"}
  ]

  # LLM 자기완결 루프 — 가이드 §9. {단계, 명령/행동}.
  @llm_steps [
    {"1", "확장 코드 작성 (디렉토리 → 퍼사드 → 로직 → LiveView → extension.ex → config)"},
    {"2", "mix ext.verify OpenMes.Addons.{Name}.Extension"},
    {"3", "❌ 있으면 → 안내(→ 줄) 따라 수정 후 2 재실행 (수렴까지)"},
    {"4", "전부 ✅ → mix compile --warnings-as-errors"},
    {"5", "mix test  (실패 시 수정 → 4)"},
    {"6", "모두 통과 = 개발 완료(DoD)"}
  ]

  # mix ext.verify 체크 7종 — 가이드 §8. {코드, 검사, 방법}.
  @verify_checks [
    {"C1", "필수 6 콜백 구현", "behaviour introspection 으로 유도(하드코딩 0)"},
    {"C2", "behaviour 채택", "@behaviour OpenMes.Extensions.Extension"},
    {"C3", "config :extensions 등록", "Registry.modules() 포함"},
    {"C4", "카탈로그 노출 가능", "Registry.all() 에서 raise 없이 엔트리화"},
    {"C5", "id 고유성", "등록 확장 간 id 중복 0 + atom"},
    {"C6", "category 유효성", "Extension.categories() 기준"},
    {"C7", "코어 비침투(휴리스틱)", "확장 소스의 명백한 Repo 직접 쓰기 grep"}
  ]

  # 샘플 리포트(LLM 파싱 친화) — 가이드 §8.
  @sample_report """
  ext.verify: OpenMes.Addons.MyReport.Extension
    ✅ C1 필수 콜백 6개 구현
    ✅ C2 Extension behaviour 채택
    ❌ C3 config :extensions 미등록
        → config :open_mes, :extensions 리스트에 모듈 한 줄 추가
    ✅ C4 카탈로그 노출 가능
    ✅ C5 id 고유 (:addon_my_report)
    ✅ C6 category 유효 (:analytics)
    ✅ C7 코어 비침투 (직접 쓰기 0건)

  결과: 6/7 통과 ❌  (종료코드 1)
  """

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "확장 개발 가이드",
       sample_extension: @sample_extension,
       sample_config: @sample_config,
       required_callbacks: @required_callbacks,
       optional_callbacks: @optional_callbacks_doc,
       llm_steps: @llm_steps,
       verify_checks: @verify_checks,
       sample_report: @sample_report
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      current_path={@current_path}
      current_actor={@current_actor}
      current_role={@current_role}
      flash={@flash}
    >
      <.page_header
        title="확장 개발 가이드"
        subtitle="회사에 맞는 확장을 직접 만드는 법 — 코어 비침투, config on/off, 카탈로그 자동 노출."
        roles={["system_admin"]}
      >
        <:actions>
          <.link navigate={~p"/extensions"} class="text-sm font-medium text-indigo-600 hover:text-indigo-500">
            ← 카탈로그로
          </.link>
        </:actions>
      </.page_header>

      <div class="space-y-6">
        <%!-- 1. 확장이란 --%>
        <section class="rounded-lg border border-zinc-200 bg-white p-6 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">1. 확장이란</h2>
          <p class="mt-2 text-sm text-zinc-600">
            확장은 코어 위에 얹는 독립 모듈입니다. 세 가지 약속만 지키면 됩니다.
          </p>
          <ul class="mt-3 space-y-2 text-sm text-zinc-700">
            <li>
              <span class="font-medium text-zinc-900">코어 비침투</span>
              — 코어 도메인은 확장을 참조하지 않습니다. 의존은 단방향(확장 → 코어 읽기). 코어 업그레이드와 충돌하지 않습니다.
            </li>
            <li>
              <span class="font-medium text-zinc-900">config on/off</span>
              — <code class="rounded bg-zinc-100 px-1 text-xs">config :open_mes, :extensions</code> 목록 등록 + <code class="rounded bg-zinc-100 px-1 text-xs">enabled?/0</code> 게이트로 켜고 끕니다.
            </li>
            <li>
              <span class="font-medium text-zinc-900">카탈로그 자동 노출</span>
              — <code class="rounded bg-zinc-100 px-1 text-xs">Extension</code> behaviour만 구현하면 카탈로그 카드가 자동으로 뜹니다.
            </li>
          </ul>
        </section>

        <%!-- 2. SDK 레퍼런스: behaviour 콜백 --%>
        <section class="rounded-lg border border-zinc-200 bg-white p-6 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">2. Extension SDK 레퍼런스</h2>
          <p class="mt-2 text-sm text-zinc-600">
            <code class="rounded bg-zinc-100 px-1 text-xs">OpenMes.Extensions.Extension</code> behaviour는 메타데이터만 계약합니다.
          </p>

          <h3 class="mt-4 text-sm font-semibold text-zinc-800">필수 콜백 6개</h3>
          <div class="mt-2 overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead>
                <tr class="border-b border-zinc-200 text-xs uppercase text-zinc-400">
                  <th class="py-2 pr-4 font-medium">콜백</th>
                  <th class="py-2 pr-4 font-medium">타입</th>
                  <th class="py-2 font-medium">설명</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{cb, type, desc} <- @required_callbacks} class="border-b border-zinc-100">
                  <td class="py-2 pr-4 font-mono text-xs text-indigo-700">{cb}</td>
                  <td class="py-2 pr-4 font-mono text-xs text-zinc-500">{type}</td>
                  <td class="py-2 text-zinc-700">{desc}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <h3 class="mt-4 text-sm font-semibold text-zinc-800">
            선택 콜백 2개 <span class="font-normal text-zinc-500">(Definition이 기본값 nil 주입)</span>
          </h3>
          <div class="mt-2 overflow-x-auto">
            <table class="w-full text-left text-sm">
              <tbody>
                <tr :for={{cb, type, desc} <- @optional_callbacks} class="border-b border-zinc-100">
                  <td class="py-2 pr-4 font-mono text-xs text-indigo-700">{cb}</td>
                  <td class="py-2 pr-4 font-mono text-xs text-zinc-500">{type}</td>
                  <td class="py-2 text-zinc-700">{desc}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="mt-3 text-xs text-zinc-500">
            카테고리: <code class="rounded bg-zinc-100 px-1">:ingest · :media · :production · :quality · :traceability · :analytics</code>
          </p>
        </section>

        <%!-- 3. 최소 확장 만들기 --%>
        <section class="rounded-lg border border-zinc-200 bg-white p-6 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">3. 최소 확장 만들기</h2>
          <p class="mt-2 text-sm text-zinc-600">
            <code class="rounded bg-zinc-100 px-1 text-xs">use OpenMes.Extensions.Definition</code> 한 줄로 선택 콜백 기본값이 주입됩니다. 필수 6개만 구현하면 됩니다.
          </p>
          <pre class="mt-3 overflow-x-auto rounded-md bg-zinc-900 p-4 text-xs leading-relaxed text-zinc-100"><code>{@sample_extension}</code></pre>
        </section>

        <%!-- 4. 등록 --%>
        <section class="rounded-lg border border-zinc-200 bg-white p-6 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">4. 등록 (config :open_mes, :extensions)</h2>
          <p class="mt-2 text-sm text-zinc-600">
            만든 확장 모듈을 config 목록에 한 줄 추가하고 서버를 재시작하면 카탈로그에 자동으로 나타납니다.
          </p>
          <pre class="mt-3 overflow-x-auto rounded-md bg-zinc-900 p-4 text-xs leading-relaxed text-zinc-100"><code>{@sample_config}</code></pre>
          <p class="mt-3 text-xs text-zinc-500">
            검증: <code class="rounded bg-zinc-100 px-1">mix ext.verify OpenMes.Addons.MyReport.Extension</code>
          </p>
        </section>

        <%!-- 4.5 자동 검증 — mix ext.verify --%>
        <section class="rounded-lg border border-zinc-200 bg-white p-6 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">자동 검증 — mix ext.verify</h2>
          <p class="mt-2 text-sm text-zinc-600">
            introspection + grep 만으로(외부 deps·서버·Repo 0) 확장 계약을 정적 검증합니다. 종료코드: 통과 0 / 위반 1.
          </p>
          <pre class="mt-3 overflow-x-auto rounded-md bg-zinc-900 p-3 text-xs text-zinc-100"><code>mix ext.verify OpenMes.Addons.MyReport.Extension   # 단일{"\n"}mix ext.verify                                       # 전체 스캔</code></pre>

          <h3 class="mt-4 text-sm font-semibold text-zinc-800">체크 7종</h3>
          <div class="mt-2 overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead>
                <tr class="border-b border-zinc-200 text-xs uppercase text-zinc-400">
                  <th class="py-2 pr-4 font-medium">#</th>
                  <th class="py-2 pr-4 font-medium">검사</th>
                  <th class="py-2 font-medium">방법</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{code, check, how} <- @verify_checks} class="border-b border-zinc-100">
                  <td class="py-2 pr-4 font-mono text-xs text-indigo-700">{code}</td>
                  <td class="py-2 pr-4 text-zinc-800">{check}</td>
                  <td class="py-2 font-mono text-xs text-zinc-500">{how}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <h3 class="mt-4 text-sm font-semibold text-zinc-800">샘플 리포트 (LLM 파싱 친화)</h3>
          <pre class="mt-2 overflow-x-auto rounded-md bg-zinc-900 p-4 text-xs leading-relaxed text-zinc-100"><code>{@sample_report}</code></pre>
          <p class="mt-3 rounded-md bg-amber-50 p-3 text-xs text-amber-900">
            C7(코어 비침투)은 grep 휴리스틱이라 <span class="font-medium">명백한 Repo 직접 쓰기</span>만 잡습니다.
            도메인 쓰기 확장은 C7 통과해도 qa-auditor <code class="rounded bg-amber-100 px-1">audit-verify</code> 가 필수입니다.
          </p>
        </section>

        <%!-- 4.6 LLM 자기완결 개발 루프 --%>
        <section class="rounded-lg border border-zinc-200 bg-white p-6 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">LLM 자기완결 개발 루프</h2>
          <p class="mt-2 text-sm text-zinc-600">
            LLM 코딩 에이전트는 사람 개입 없이 아래 루프를 <span class="font-medium text-zinc-900">수렴까지</span> 돌립니다.
          </p>
          <ol class="mt-3 space-y-2 text-sm text-zinc-700">
            <li :for={{step, action} <- @llm_steps} class="flex gap-3">
              <span class="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-indigo-100 text-xs font-semibold text-indigo-700">{step}</span>
              <code class="rounded bg-zinc-100 px-1 text-xs leading-5">{action}</code>
            </li>
          </ol>
          <p class="mt-3 text-xs text-zinc-500">
            완료 정의(DoD): <code class="rounded bg-zinc-100 px-1">mix ext.verify</code> 전부 ✅ +
            <code class="rounded bg-zinc-100 px-1">mix compile --warnings-as-errors</code> +
            <code class="rounded bg-zinc-100 px-1">mix test</code> 통과.
          </p>
        </section>

        <%!-- 5. 빌딩블록 + 6. 데이터 원칙 --%>
        <section class="rounded-lg border border-zinc-200 bg-white p-6 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">5. 재사용 빌딩블록 & 데이터 원칙</h2>
          <ul class="mt-3 space-y-2 text-sm text-zinc-700">
            <li>
              <span class="font-medium text-zinc-900">SVG 차트</span> — <code class="rounded bg-zinc-100 px-1 text-xs">OpenMesWeb.ChartComponents</code> (의존성 0)
            </li>
            <li>
              <span class="font-medium text-zinc-900">관리자 UI</span> — <code class="rounded bg-zinc-100 px-1 text-xs">OpenMesWeb.AdminComponents</code> (admin_shell / page_header / 배지)
            </li>
            <li>
              <span class="font-medium text-zinc-900">컨텍스트 읽기</span> — 코어 도메인 조회 함수로 작업지시/실적/LOT/불량을 읽습니다.
            </li>
          </ul>
          <div class="mt-4 rounded-md bg-amber-50 p-4 text-sm text-amber-900">
            <p class="font-medium">데이터 접근 원칙</p>
            <ul class="mt-2 list-disc space-y-1 pl-5">
              <li>읽기 위주 — 대부분의 애드온은 코어 데이터를 읽기만 합니다(새 테이블 0).</li>
              <li>쓰기는 컨텍스트 경유 — 직접 테이블 수정 금지. 모든 쓰기는 AuditLog, 상태 변경은 동일 트랜잭션 Outbox.</li>
              <li>AI는 propose → 승인 — 직접 쓰기 금지, AiInteraction 기록.</li>
            </ul>
          </div>
        </section>

        <%!-- 7. 레퍼런스 --%>
        <section class="rounded-lg border border-zinc-200 bg-white p-6 shadow-sm">
          <h2 class="text-lg font-semibold text-zinc-900">7. 레퍼런스 — 기존 확장에서 시작하기</h2>
          <p class="mt-2 text-sm text-zinc-600">
            가장 단순한 시작점은 <span class="font-medium text-zinc-900">작업지시 CSV 내보내기</span>(<code class="rounded bg-zinc-100 px-1 text-xs">lib/open_mes_addons/wo_csv_export/</code>)입니다 —
            읽기 전용, 새 테이블 0, behaviour 구현 + 화면 + 컨텍스트 읽기의 전형입니다.
          </p>
          <p class="mt-2 text-xs text-zinc-500">
            전체 가이드 문서: <code class="rounded bg-zinc-100 px-1">docs/extension-development.md</code> · 로드맵: <code class="rounded bg-zinc-100 px-1">docs/extension-roadmap.md</code>
          </p>
        </section>
      </div>
    </.admin_shell>
    """
  end
end
