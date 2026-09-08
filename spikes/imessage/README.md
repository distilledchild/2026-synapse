# iMessage 읽기 전용 실현성 검증

2026-09-06. 첫 플랫폼을 iMessage로 좁힌 Phase 0 시제품이다. 제품용 Rust 커넥터나 GUI가 아니며 추가 패키지가 없는 Python 표준 라이브러리로 DB 접근 계약을 검증한다. 현재 Mac에서 Python 3.9.6으로 테스트했으며, 제품 런타임에 Python을 추가하는 결정은 아니다. Rust/Cargo는 현재 개발 환경에서 발견되지 않았다.

## 선택 근거

macOS 전용 제품에서 첫 수신 결과를 빠르게 확인하는 것을 우선했다. iMessage는 별도 서비스 로그인 흐름을 구현하기 전에 로컬 DB 읽기부터 검증할 수 있다. 이는 초기 읽기 실험의 난이도 판단이며, 전체 메시지 형식·실시간 수정/삭제·발신까지 쉽다는 의미는 아니다.

사용자 규모만으로 iMessage가 1위라고 판단하지 않는다. Telegram은 공식 페이지에서 월간 사용자 10억 명을 안내하며 공식 클라이언트 라이브러리 TDLib가 있어 두 번째 후보로 둔다. 글로벌 배포와 공식 클라이언트 API를 우선하면 Telegram을 먼저 선택할 수 있다. WhatsApp은 개인 인박스용 연결 방식 검증이 남아 있어 이번 첫 실험에서는 제외한다.

## 실행

아래 명령은 프로젝트 루트에서 실행한다. 별도 설치·빌드가 필요 없다.

```sh
python3 -B spikes/imessage/probe.py --demo
python3 -B spikes/imessage/probe.py --demo --show-content
python3 -B -m unittest discover -s spikes/imessage -v
```

실제 DB는 자동으로 열지 않는다. macOS 메시지 동기화와 권한을 확인한 뒤, 사용자가 명시한 경로에만 접근한다. 기본 출력은 건수·본문 상태·커서이며 본문과 대화 식별자를 출력하지 않는다.

```sh
python3 -B spikes/imessage/probe.py --db "$HOME/Library/Messages/chat.db" --limit 100
python3 -B spikes/imessage/probe.py --db "$HOME/Library/Messages/chat.db" --after 123 --watch
```

`--show-content`를 추가하면 본문과 식별자가 터미널에 표시된다. 현재 테스트에서는 실제 개인 메시지를 읽거나 저장하지 않았다. 외부 통신·메시지 발신·권한 설정 변경은 없다.

## 동작과 한계

- SQLite URI `mode=ro`와 연결 단위 `query_only`를 사용한다. 원본 DB 설정·checkpoint·migration은 수행하지 않는다. SQLite가 읽기 잠금용 공유 메모리를 사용할 수 있어 디렉터리 전체가 바이트 단위 불변이라고 주장하지 않는다.
- ROWID 기준 페이지를 먼저 정하고 대화에 연결한다. 하나의 메시지가 여러 대화에 연결된 경우 페이지 경계에서 누락되지 않는다.
- `--watch`는 새 행을 주기적으로 조회하는 실험이다. 수정·삭제·나중에 추가되는 대화 연결·ROWID 재사용·DB 교체 복구는 미지원이다. 커서는 같은 DB에만 재사용한다. 체크포인트를 디스크에 자동 저장하지 않는다.
- 최신 DB 날짜 단위는 기본 nanoseconds로 가정한다. 구형 seconds 데이터는 `--date-unit seconds`로 명시한다. 자동 추측하지 않는다.
- 일반 `text`는 정규화하지만 `attributedBody`는 해독하지 않는다. 해당 메시지는 `unsupported_attributed_body`로 표시하고 누락을 숨기지 않는다. 첨부 다운로드, 발신자 조회, 리액션/시스템 이벤트 구분은 미구현이다.
- 이는 전체 UnifiedMessage 계약의 부분 집합이다. DB 스키마 확인·페이지 읽기·본문 지원율을 확인하기 위한 probe이며 앱용 저장소/검색·암호화 캐시가 아니다.
- 접근 실패는 잘못된 경로, 전체 디스크 접근 권한, 파일 권한, 잠금/손상 가능성을 안내하고 종료한다. 자동 재인증·재연결은 제품 단계 과제다.

## 검증 결과와 다음 게이트

합성 데이터 테스트 11개 통과: 읽기 전용/원본 DB 불변, 없는 DB 생성 방지, 일반/미지원/첨부 본문 상태, 날짜 변환, 페이지 경계/중복 연결, 계정 식별, WAL 새 메시지 가시성, 미지원 스키마, 구형 선택 컬럼, 기본 출력 비식별, CLI 오류.

실제 macOS DB 접근, 권한 철회, attributedBody 해독, 잠자기 복귀, 메시지 수정/삭제는 아직 검증하지 않았다. 따라서 계획의 P0-02 전체를 완료로 표시하지 않는다. 다음에는 명시적으로 허용된 DB에서 본문을 출력하지 않는 진단을 수행하고, 지원 범위를 측정한 뒤 Rust 드라이버 구현으로 옮긴다. 외부 본문 해독 라이브러리 채택 시 라이선스·버전·배포 조건을 먼저 확인한다.

자료(2026-09-06 확인):

- [Telegram 공식 API 및 사용자 규모 안내](https://core.telegram.org/)
- [TDLib 시작 안내](https://core.telegram.org/tdlib/getting-started)
- [Apple 문자 메시지 전달 안내](https://support.apple.com/en-au/102545): SMS/MMS/RCS의 Mac 표시에는 사용자 환경 설정이 관여한다.
- [imessage-exporter 프로젝트](https://github.com/ReagentX/imessage-exporter): 읽기 전용 접근과 다양한 메시지 형식을 다루는 참고 구현. 이 시제품은 해당 코드를 복사하거나 의존성으로 포함하지 않는다.
- [Python SQLite 문서](https://docs.python.org/3.9/library/sqlite3.html): URI 기반 읽기 전용 연결.
