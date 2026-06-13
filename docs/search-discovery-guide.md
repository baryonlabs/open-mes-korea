# 검색 및 발견성 운영 가이드

Open MES Korea 공식 사이트:

```text
https://baryonlabs.github.io/open-mes-korea/
```

## 현재 준비된 항목

- 고유 `title`과 description
- Open Graph 및 X/Twitter 카드
- 1200×630 공유 이미지
- canonical URL
- Schema.org `WebSite`와 `SoftwareSourceCode`
- `robots.txt`
- `sitemap.xml`
- `llms.txt`
- 10개 언어 UI
- GitHub 저장소 homepage, description, topics

## Google Search Console

GitHub Pages 프로젝트 사이트는 경로가 포함되므로 **URL 접두어 속성**으로
다음 주소를 정확히 등록한다.

```text
https://baryonlabs.github.io/open-mes-korea/
```

1. Search Console에서 속성 추가를 선택한다.
2. URL 접두어 방식으로 위 전체 주소를 입력한다.
3. HTML 태그 또는 HTML 파일 방식으로 소유권을 확인한다.
4. 발급받은 값은 공개 이슈에 올리지 말고 저장소 관리자가 직접 추가한다.
5. 아래 sitemap을 제출한다.

```text
https://baryonlabs.github.io/open-mes-korea/sitemap.xml
```

6. URL 검사에서 공식 사이트 URL의 색인 생성을 요청한다.

## Bing Webmaster Tools

1. Bing Webmaster Tools에 사이트를 추가한다.
2. 가능하면 Google Search Console에서 가져오거나 별도로 소유권을 확인한다.
3. 동일한 `sitemap.xml`을 제출한다.
4. Site Scan으로 기술적 SEO 오류를 점검한다.
5. 주요 변경 뒤 URL Submission을 사용한다.

## 네이버 서치어드바이저

네이버는 사이트 등록을 호스트 단위로 지원한다. 현재 주소는
`baryonlabs.github.io` 아래의 프로젝트 경로이므로 프로젝트 경로만 별도
사이트로 등록하기 어렵다.

한국 검색 노출을 본격 운영하려면 다음 중 하나가 필요하다.

1. Open MES Korea 전용 도메인을 연결한다.
2. `baryonlabs.github.io` 루트 사이트의 소유권을 확인하고 운영한다.

전용 도메인을 연결한 뒤:

- 사이트 등록 및 HTML 소유 확인
- sitemap 제출
- 주요 변경 후 페이지 수집 요청
- 검색 진단 리포트 확인

## IndexNow

IndexNow는 변경된 URL을 참여 검색엔진에 알릴 수 있다. 사이트 호스트의
소유권을 키 파일로 증명해야 한다.

현재처럼 GitHub Pages 하위 경로를 사용할 때보다 전용 도메인을 연결한
뒤 적용하는 편이 운영과 소유권 관리가 명확하다.

## 전용 도메인 권장

검색 브랜드를 장기 운영하려면 GitHub Pages 기본 경로보다 전용 도메인이
유리하다.

- 검색엔진 소유권 확인이 단순해진다.
- 네이버 호스트 단위 등록이 가능하다.
- URL이 짧고 기억하기 쉽다.
- 향후 사이트 플랫폼을 바꿔도 주소를 유지할 수 있다.
- 이메일과 프로젝트 브랜드를 같은 도메인으로 통합할 수 있다.

도메인을 연결할 경우 canonical, Open Graph URL, sitemap, robots,
`llms.txt`의 절대 주소를 모두 새 도메인으로 변경해야 한다.

## GitHub 발견성 운영

GitHub Trending은 등록 신청 방식이 아니며 노출을 보장할 수 없다.
일반적으로 단기간의 실제 관심과 활동이 중요하므로 다음을 지속한다.

- 릴리스 가능한 작은 마일스톤을 정기적으로 공개
- 실행 가능한 데모와 설치 방법 제공
- 첫 기여 이슈를 작고 명확하게 유지
- Issues와 Discussions에 빠르게 응답
- 변경 내용을 릴리스 노트와 외부 게시글로 공유
- 문서만이 아니라 작동하는 코어 기능을 계속 공개
- 인위적인 star 교환이나 자동화된 홍보는 사용하지 않음

## 등록 후 점검 주기

| 주기 | 점검 |
|---|---|
| 배포 때마다 | 페이지, 메타 태그, sitemap, 깨진 링크 |
| 매주 | Search Console/Bing 색인 오류와 검색어 |
| 매월 | 유입 페이지, 클릭률, README 전환, 반복 검색어 |
| 릴리스 때 | URL 제출, 소개 게시물, Discussions 공지 |

## 공식 참고

- [Google Search Console: 속성 추가](https://support.google.com/webmasters/answer/34592)
- [Google Search Console: 소유권 확인](https://support.google.com/webmasters/answer/9008080)
- [Google Search Console: sitemap 보고서](https://support.google.com/webmasters/answer/7451001)
- [Bing Webmaster Tools: 시작 체크리스트](https://www.bing.com/webmasters/help/getting-started-checklist-66a806de)
- [Bing Webmaster Tools: sitemap](https://www.bing.com/webmasters/help/Sitemaps-3b5cf6ed)
- [네이버 서치어드바이저](https://searchadvisor.naver.com/)
- [IndexNow 공식 문서](https://www.indexnow.org/documentation)
