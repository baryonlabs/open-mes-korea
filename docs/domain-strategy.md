# 도메인 전략

확인일: 2026-06-13

## 권장 구성

### 주 도메인

```text
openmeskorea.org
```

선정 이유:

- 프로젝트 이름과 정확히 일치한다.
- 기존 `OpenMES` 프로젝트와 구분된다.
- 오픈소스 커뮤니티와 비영리적 공개 프로젝트 성격을 전달한다.
- 국가와 언어가 확장되어도 프로젝트의 한국 제조 출발점을 유지한다.
- Google, Bing, 네이버 사이트 소유권과 canonical URL을 독립 관리할 수 있다.

### 보호 및 리디렉션

```text
openmeskorea.com → openmeskorea.org
openmes.kr       → openmeskorea.org/ko 또는 주 도메인
```

- `.com`: 이름 선점 방지와 일반 사용자의 오입력 대응
- `.kr`: 한국 제조사 대상 홍보와 짧은 로컬 주소

## 피할 주 도메인

```text
openmes.io
openmes.dev
open-mes.org
```

`OpenMES`라는 이름을 사용하는 기존 오픈소스 MES와 상용·교육용 제품이
이미 검색 결과에 존재한다. 짧은 `openmes.*` 주소는 기존 프로젝트와
혼동될 가능성이 높고, 특히 `.io`는 갱신 비용도 높은 편이다.

## 도메인 연결 체크리스트

1. GitHub Pages custom domain과 `CNAME`
2. HTTPS 인증서와 강제 HTTPS
3. GitHub 저장소 homepage URL
4. canonical URL
5. Open Graph와 X/Twitter URL 및 이미지
6. `sitemap.xml`, `robots.txt`
7. `llms.txt` 내부 절대 링크
8. Form2AI2Email CORS 허용 origin
9. Google Search Console URL-prefix 또는 Domain 속성
10. Bing Webmaster Tools와 네이버 서치어드바이저
11. IndexNow key host와 제출 URL
12. README, 이메일, LinkedIn과 외부 게시글 링크

## DNS 권장

GitHub Pages 공식 안내에 맞춰 apex와 `www`를 함께 구성한다.

| Type | Name | Content | Proxy |
|---|---|---|---|
| A | `@` | `185.199.108.153` | DNS only |
| A | `@` | `185.199.109.153` | DNS only |
| A | `@` | `185.199.110.153` | DNS only |
| A | `@` | `185.199.111.153` | DNS only |
| AAAA | `@` | `2606:50c0:8000::153` | DNS only |
| AAAA | `@` | `2606:50c0:8001::153` | DNS only |
| AAAA | `@` | `2606:50c0:8002::153` | DNS only |
| AAAA | `@` | `2606:50c0:8003::153` | DNS only |
| CNAME | `www` | `baryonlabs.github.io` | DNS only |

```text
openmeskorea.org     → GitHub Pages
www.openmeskorea.org → openmeskorea.org
```

GitHub Pages가 apex 도메인을 canonical custom domain으로 사용하므로
`www` 요청은 apex로 자동 리디렉션된다. 인증서 발급과 DNS 진단이 끝날
때까지 Cloudflare 프록시는 끄고 `DNS only`로 유지한다. GitHub Pages에서
HTTPS가 활성화된 뒤 DNSSEC와 자동 갱신 상태도 확인한다.

## 운영 확인

- 자동 갱신과 결제 수단이 정상인가?
- WHOIS privacy, DNSSEC와 2단계 인증이 활성화되어 있는가?
- 조직 계정으로 소유권과 자동 갱신을 관리하는가?
- 결제와 복구 연락처가 개인 한 명에게만 묶이지 않는가?

## 등록 상태

`openmeskorea.org`는 2026-06-13 Cloudflare Registrar를 통해 등록했다.
공식 사이트와 모든 canonical URL은 이 도메인을 사용한다.

`openmeskorea.com`과 `openmes.kr`은 선택적인 브랜드 보호 도메인으로
남겨 둔다.

## 참고

- 기존 OpenMES 프로젝트: https://getopenmes.com/
- 기존 OpenMES GitHub: https://github.com/Mes-Open/OpenMes
- GitHub Pages custom domain:
  https://docs.github.com/pages/configuring-a-custom-domain-for-your-github-pages-site
