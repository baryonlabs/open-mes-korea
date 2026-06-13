# 검색 및 발견성 운영 가이드

Open MES Korea 공식 사이트:

```text
https://openmeskorea.org/
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

전용 도메인은 **도메인 속성**으로 등록하는 것을 권장한다. Cloudflare
DNS에 Search Console이 제공하는 TXT 레코드를 추가하면 모든 프로토콜과
하위 도메인을 함께 관리할 수 있다.

```text
https://openmeskorea.org/
```

1. Search Console에서 속성 추가를 선택한다.
2. 도메인 방식으로 `openmeskorea.org`를 입력한다.
3. 발급된 TXT 레코드를 Cloudflare DNS에 추가해 소유권을 확인한다.
4. 발급받은 값은 공개 이슈에 올리지 말고 저장소 관리자가 직접 추가한다.
5. 아래 sitemap을 제출한다.

```text
https://openmeskorea.org/sitemap.xml
```

6. URL 검사에서 공식 사이트 URL의 색인 생성을 요청한다.

## Bing Webmaster Tools

1. Bing Webmaster Tools에 사이트를 추가한다.
2. 가능하면 Google Search Console에서 가져오거나 별도로 소유권을 확인한다.
3. 동일한 `sitemap.xml`을 제출한다.
4. Site Scan으로 기술적 SEO 오류를 점검한다.
5. 주요 변경 뒤 URL Submission을 사용한다.

## 네이버 서치어드바이저

네이버 서치어드바이저에는 전용 도메인을 사이트로 등록한다.

- 사이트 등록 및 HTML 소유 확인
- sitemap 제출
- 주요 변경 후 페이지 수집 요청
- 검색 진단 리포트 확인

## IndexNow

IndexNow는 변경된 URL을 참여 검색엔진에 알릴 수 있다. 사이트 호스트의
소유권을 키 파일로 증명해야 한다.

배포 워크플로가 변경된 공식 URL을 IndexNow에 자동으로 알린다.

## 전용 도메인 운영

공식 도메인은 `openmeskorea.org`이며 GitHub Pages에 연결한다.

- 검색엔진 소유권 확인이 단순해진다.
- 네이버 호스트 단위 등록이 가능하다.
- URL이 짧고 기억하기 쉽다.
- 향후 사이트 플랫폼을 바꿔도 주소를 유지할 수 있다.
- 이메일과 프로젝트 브랜드를 같은 도메인으로 통합할 수 있다.

canonical, Open Graph URL, sitemap, robots, `llms.txt`, IndexNow의
절대 주소는 모두 공식 도메인을 사용한다.

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
