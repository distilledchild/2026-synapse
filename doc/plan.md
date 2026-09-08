# 2026-synapse 시스템 아키텍처 및 구현 계획

문서 버전: 2.2.0 · 갱신: 2026-09-07 · 상태: Apple 메시지 읽기·텍스트/사진 전송 로컬 알파 구현

## 1. 제품 목표와 현재 상태

여러 서비스의 대화를 macOS 앱의 통합 인박스에서 확인하고, 허용된 범위에서 답장·검색하는 로컬 우선 메시징 허브를 만든다. 15개 서비스는 장기 후보 목록이며 현재는 SwiftUI 기반 Apple 메시지 읽기·텍스트/사진 전송 로컬 알파가 있다. 실제 계정 발신은 아직 미검증이다. 나머지 커넥터는 미구현이다. 이 문서의 선택은 개발 기준안이고, 검증 항목은 통과 전까지 지원 기능으로 표시하지 않는다.

초기 사용자 흐름은 계정 연결 → 수집 범위 선택 → 초기 동기화 → 시간순 인박스 → 대화 열람 → 검색이다. SwiftUI 알파에는 기존 iMessage·SMS·RCS 대화에 텍스트 발신을 추가했으며 장기 통합 outbox는 후속이다. 클라우드 중계 서버는 초기 범위에서 제외하지만 원래 메시징 서비스와의 통신은 필요하다.

### 1.1 현재 산출물과 미완료 기능

- `native/`: SwiftUI/Swift/시스템 SQLite로 만든 0.2.7 로컬 알파. Rust 도구가 없는 현재 개발 환경에서 설치 테스트를 우선하기 위한 임시 독립 경로이며 아래 Tauri/Rust 장기 설계와 구분한다.
- `releases/0.2.7/`: Apple Silicon DMG, 소스 ZIP, 체크섬, 설치 안내. `spikes/imessage/`에는 최초 읽기 실험을 보관한다.
- 구현: 최근 2,000개 메시지 조회, 제한된 attributedBody 해독, 검색, 5초 갱신, 권한 안내, 연결 해제. 읽기 합성 데이터 44개·전송 54개·연락처 31개·입력/이미지 21개·사진 전송 24개 검사(총 174개) 통과.
- 미검증: 실제 사용자 계정/권한, 모든 본문 형식, DMG 마운트·설치, 지원 대상 OS 전체.
- **입력·이미지**: Enter 전송·Shift+Enter 줄바꿈 및 IME 조합 보호. 로컬에 내려받은 첨부 이미지의 축소 미리보기·클릭 확대를 구현했으며 합성 데이터로 검증했다. 제공된 링크의 실제 캐시 이미지 디코딩을 확인했다. 링크 payload의 제목·주 썸네일과 기본 한 줄·자동 확장 작성창을 추가했다.
- **연락처 표시**: Contacts 권한 허용 후 저장된 이름·이니셜과 이름 검색을 제공한다. 가져온 DB는 연락처 조회에서 제외한다. 합성 연락처 UI 검증을 통과했으며 실제 연락처 권한 흐름은 미검증이다. 작성창의 내부 ID·중복 안내를 제거했다.
- **보내기**: 기존 iMessage·SMS·RCS 대화에 텍스트 또는 사진 한 장 전송을 구현했다. 사진은 20 MiB 이내이며 선택 시 파일 해시와 전송 직전 내용을 검증한다. Messages.sdef의 정확한 `chat id`를 확인하고 `send`를 호출한다. 대화별 메모리 초안, Automation 권한 안내, 중복 클릭 방지, 오류/결과 불명 처리, 별도 helper 프로세스·타임아웃을 포함한다. 샘플과 가져온 DB는 실제 발신하지 않는다. 실제 계정 발신·권한 흐름은 미검증이며 새 대화·동영상/일반 파일 전송과 영속 outbox는 미구현이다.
- **수정·삭제**: 현재 Messages 자동화 사전에 개별 message 객체/수정·삭제 명령이 노출되지 않는다. Apple 메시지 앱 기능과 자동화 지원 범위를 혼동하지 않는다. 별도 UI 자동화 방식은 권한·정확성·OS 호환성 검증 전 제품 기능으로 약속하지 않는다.
- 로컬 DB 행 수정·삭제를 실제 iMessage 수정·삭제/발신 취소의 대체로 구현하지 않는다. 삭제와 발신 취소는 다른 동작이다.

## 2. MVP 범위와 기술 결정

| 항목 | 개발 기준안 | 검증 또는 제외 범위 |
|---|---|---|
| 대상 | Apple Silicon macOS, 직접 설치 DMG | 최소 macOS 버전은 Phase 0에서 실제 기기와 SDK 기준으로 확정; Intel은 후속 |
| UI | Tauri v2 + React + TypeScript + Vite | 번들된 UI만 로드; 웹 서비스를 iframe으로 나열하지 않음 |
| 코어 | Rust, Tokio 기반 비동기 작업 | 앱 프로세스가 수명 관리; 별도 상주 데몬은 MVP 제외 |
| 저장 | SQLite 호환 SQLCipher + FTS5를 우선 검증 | 암호화·FTS5·마이그레이션·패키징 동시 검증 실패 시 실데이터 저장 단계 보류 |
| 비밀정보 | macOS Keychain | UI·일반 설정·로그에 토큰과 DB 키 저장 금지 |
| Telegram | TDLib JSON 인터페이스를 Rust 어댑터로 연결 | api_id/api_hash, 로그인·2FA·세션 재개·번들 의존성 검증 |
| iMessage | 로컬 DB 읽기 전용 어댑터 | macOS 버전별 스키마·권한·본문 형식 차이 검증 |
| 기타 런타임 | 필요성이 검증된 커넥터에만 sidecar 허용 | Node/Go를 처음부터 동시에 도입하지 않음 |
| 검증 도구 | Rust 단위/통합 테스트, Vitest, React Testing Library, Playwright | Playwright는 웹 UI 검증; 실제 macOS 권한·DMG는 별도 기기 검증 |
| 업데이트 | 초기 내부 알파는 수동 설치 | 자동 업데이트는 서명 검증·복구 설계 후 추가 |

MVP 필수 기능: iMessage·Telegram 텍스트 수신, 계정/플랫폼 필터, 페이지 단위 대화 열람, 연결 상태와 재인증 안내, 로컬 검색, 안전한 연결 해제 및 캐시 삭제. 초기에는 플랫폼당 한 계정만 노출하되 데이터 모델은 다중 계정을 지원한다.

MVP 제외: 모든 과거 대화의 완전 수집 보장, 통화, 모든 첨부 형식, 플랫폼 간 읽음 동기화, 연락처 자동 병합, AI 자동 답장, 15개 동시 출시. iMessage 검증 실패 시 Telegram+합성 데이터로 내부 알파를 진행하고 iMessage 지원을 표시하지 않는다.

## 3. 플랫폼별 도입 게이트

아래는 구현 순서와 조사 과제다. 공식 자료 확인은 문서 말미에 명시한 4개 항목에 한정되며 나머지 API 접근성과 정책은 미검증이다. 각 커넥터 착수 전 인증 주체, 읽기·쓰기 권한, 이력 접근 범위, 요금/쿼터, 배포 조건, SDK 라이선스 및 유지보수 상태를 기록한다.

| 서비스 | 후보 방식 | 다음 검증과 도입 조건 |
|---|---|---|
| iMessage/SMS | chat.db 읽기; 후속 AppleScript 발신 | 전체 디스크 접근 권한 거부/철회, 본문·첨부·그룹·재시작·잠자기 복귀 테스트; SMS는 사용 환경별 실증 |
| Telegram | TDLib | 테스트 계정 수신·이력·재연결, 세션 암호화, 네이티브 라이브러리 패키징 통과 후 MVP |
| Slack | Events API + Socket Mode | 승인된 토큰·scope·참여 대화에 대한 접근 확인; 개인 계정의 모든 DM 수집으로 표현하지 않음 |
| Discord | 공식 bot API | 개인 계정 self-bot 제외; 허용된 봇 대화/서버 이벤트만 별도 확장. 개인 DM 통합 대체물로 취급하지 않음 |
| WhatsApp | Baileys 또는 Whatsmeow 비교 | 비공식 연결 방식의 계정·재인증·배포 조건과 운영 안정성 검증 후 하나만 선택; MVP 제외 |
| Instagram | 공식 메시징 API 후보 | 지원 계정 유형·앱 심사·수신/답장 범위 확인 전 보류 |
| Facebook Messenger | 공식 Graph API 후보 | 페이지/개인 메시지 접근 구분과 권한 확인 전 보류 |
| X | 공식 DM API 후보 | 접근 요금·권한·이력·이벤트 지원 확인; 세션 쿠키 방식은 기본 경로로 채택하지 않음 |
| Threads | 공식 API 후보 | 멘션·답글과 DM을 구분하고 실제 지원 기능만 채택; ActivityPub을 DM 보장 근거로 사용하지 않음 |
| TikTok | 공식 접근 가능성 조사 | 일반 사용자 DM 접근 경로 확인 전 보류 |
| Twitch | 공식 이벤트·메시징 API 조사 | Whisper와 채널 멘션의 권한·이벤트 경로를 각각 검증 |
| KakaoTalk | 공식 접근/로컬 알림 수집 조사 | 알림 수집과 전체 대화 동기화를 구분; 누락·본문 제한 검증 전 지원 약속 없음 |
| LINE | 공식 API 조사 | 비즈니스 계정 메시징과 개인 인박스 접근 구분; Phase 3 조사에 포함 |
| Signal | signal-cli 후보 | 연결 기기·세션 보관·업데이트·배포 의존성 검증 |
| LinkedIn | 공식 메시징 접근 조사 | 파트너 권한 등 접근 조건 확인 전 보류; Phase 3 조사에 포함 |

출시 지원표에는 플랫폼 단위 체크 대신 수신/이력/발신/수정/삭제/첨부/읽음 동기화별 상태를 표기한다. 상태는 미검증, 실험적, 지원, 미지원으로 구분한다.

## 4. 구조와 책임

```text
2026-synapse/
├── README.md
├── doc/plan.md
├── doc/decisions/          # 검증 결과와 기술 선택 기록 (예정)
├── ui/                    # React 화면·타입·UI 테스트 (예정)
├── src-tauri/             # 앱 진입점·IPC·권한·번들 설정 (예정)
├── core/                  # 도메인·저장소·동기화·검색 (Rust crate, 예정)
├── drivers/               # 커넥터 공통 계약 및 구현 (예정)
├── migrations/            # 버전별 DB 변경 (예정)
├── tests/fixtures/         # 합성 데이터만 저장 (예정)
└── .github/workflows/     # CI와 macOS 패키징 (예정)
```

흐름: 커넥터 → 제한된 크기의 이벤트 큐 → 정규화 → DB 트랜잭션(메시지·인덱스·커서) → UI 변경 알림. UI는 저장된 데이터를 페이지 단위로 조회하며 원본 DB·토큰·임의 셸에 직접 접근하지 않는다. 큐가 가득 차면 커넥터별 속도를 줄이고, 복구 가능한 커서부터 재조회한다. UI 알림 손실은 DB 재조회로 복구한다.

Tauri IPC는 계정 목록, 연결/해제, 대화 조회, 검색, 발신 등 명시된 명령만 허용한다. 창별 capability를 최소화하며 외부 링크는 검증 후 시스템 브라우저로 연다. sidecar가 필요한 경우 실행 파일을 고정하고 버전 있는 JSON 메시지로 통신하며 비밀정보를 명령행 인수에 넣지 않는다.

## 5. 데이터 모델과 동기화

기존 UnifiedMessage 초안에 accountId, 버전, 수정·삭제 및 발신 상태를 추가한다. 아래는 구현용 필수 계약이며 전체 DB DDL은 Phase 0 이후 migration으로 작성한다.

```typescript
type MessageKey = {
  accountId: string;
  conversationId: string;
  originalMessageId: string;
};
interface UnifiedMessage {
  id: string; // 로컬 UUID
  schemaVersion: number;
  key: MessageKey;
  platform: string; // 구현 시 15개 후보의 명시적 enum
  senderId: string;
  text: string | null; // 첨부 전용 메시지 허용
  sentAt: number; // UTC epoch milliseconds
  receivedAt: number;
  editedAt?: number;
  deletedAt?: number;
  direction: 'incoming' | 'outgoing';
  deliveryState?: 'queued' | 'sending' | 'sent' | 'failed' | 'unknown';
  replyTo?: MessageKey;
}
```

테이블 책임:

- accounts: 플랫폼·원본 계정 ID·표시명·연결 상태·Keychain 참조. 토큰 원문은 저장하지 않는다.
- conversations / participants: 계정별 원본 대화 ID, 제목, 그룹 여부, 참여자. ID는 계정 범위로 구분한다.
- messages: 위 모델; (account_id, conversation_id, original_message_id) 유일 제약으로 재수신 중복 제거.
- attachments: 원본 참조·MIME·크기·암호화 캐시 참조·다운로드 상태; 임의 원본 경로를 신뢰하지 않는다.
- sync_cursors: 계정/스트림별 체크포인트와 이력 수집 범위. 메시지 저장 성공과 같은 트랜잭션에서 전진한다.
- outbox: client_request_id 유일 제약, 대상 계정/대화, 재시도 횟수, 다음 시각, 발신 상태.
- local_read_state: 앱 내부 읽음 위치. 원격 읽음 상태와 별도로 관리한다.
- FTS 인덱스: 메시지 추가·수정·삭제와 트랜잭션 단위로 동기화한다.

커넥터 계약: capabilities(), connect(), disconnect(), fetchHistory(cursor, limit), subscribe(cursor), send(request). 수정/삭제/읽음은 지원되는 커넥터에만 선택적으로 추가한다. 상태는 disconnected → connecting → syncing → ready, 예외 상태는 reconnecting / auth_required / permission_required / error로 표현한다.

이벤트에는 계정 ID, 이벤트 종류, 원본 ID, 제공되는 원본 버전/시각을 포함한다. 삭제 tombstone을 유지해 오래된 재수신으로 메시지가 부활하지 않게 한다. 삭제가 생성보다 먼저 도착하거나 순서 정보가 부족하면 원본 재조회 또는 미해결 상태로 보관한다.

실시간 구독과 초기 이력 수집은 중첩 구간을 두고 유일 제약으로 합친다. 초기 기본 범위는 최근 30일 또는 계정당 10,000건 중 먼저 도달하는 한도이며, 서비스가 제공하지 못하는 구간은 UI에 표시한다. 커서 만료 시 마지막 확인 시점보다 앞에서 제한적으로 재동기화한다.

재연결은 지수 backoff와 jitter, 서비스의 Retry-After를 따른다. 발신 응답 유실은 unknown으로 기록하고 조회로 확인한다. 플랫폼 멱등 키가 없으면 무조건 재발신하지 않는다. queued 복원 시 대상 계정과 대화를 재검증한다.

### iMessage 특이사항

원본 chat.db를 읽기 전용으로 열고 원본의 PRAGMA 설정 변경·마이그레이션·checkpoint를 수행하지 않는다. DB/WAL 변경 감지는 재조회 신호로만 사용하고 주기적 대조 조회로 누락을 보완한다. WAL이 있는 DB 본체만 복사해 일관된 스냅샷으로 간주하지 않는다. 지원 OS에서 일반 본문과 attributedBody, 그룹 대화, 첨부 전용, 시간 변환, DB 잠김을 합성 fixture와 허가된 실제 기기로 검증한다. 새 행 ID 감시만으로 수정·삭제를 완전히 지원한다고 표시하지 않는다.

## 6. 개인정보·보관·권한

로컬 저장 암호화와 원래 서비스의 종단간 암호화는 구분한다. 앱이 복호화된 메시지를 검색하기 때문에 모든 플랫폼을 아우르는 새로운 E2EE를 제공한다고 주장하지 않는다.

DB·FTS·WAL·임시 파일에 평문이 남지 않는지 검증한다. 첨부는 별도 암호화하고 미리보기 임시 파일의 위치·삭제 정책을 정의한다. Keychain이 잠기거나 키를 읽지 못하면 저장소를 잠금 상태로 유지한다. 키 분실 시 복구할 수 없는 캐시와 원본에서 재수집 가능한 데이터를 구분해 안내한다.

전체 디스크 접근, 발신 자동화, 알림 권한은 필요한 기능을 켤 때 요청한다. 권한 거부/철회는 앱 전체 종료 대신 해당 기능 상태로 표시한다. 로그는 이벤트 종류·건수·오류 코드 중심으로 기록하며 본문·수신자·토큰은 기본 제외한다. 외부 분석·오류 업로드는 MVP에서 사용하지 않는다.

연결 해제와 로컬 데이터 삭제는 별도 동작이다. 삭제는 수집 작업 정지 → 세션 폐기 가능 여부 확인 → 계정 데이터/FTS/첨부/대기 발신 삭제 → 키 참조 정리 순서로 수행한다. 원래 서비스의 메시지는 삭제하지 않는다. 운영체제 백업이나 SSD의 물리적 완전 삭제까지 보장하지 않는다. 기본 보관 범위와 용량은 설정 화면에서 확인·변경할 수 있게 한다.

## 7. 구현 단계와 완료 기준

기간은 아직 산정하지 않는다. 각 단계의 통과 결과와 실제 작업량을 기록한 뒤 일정을 산정한다. 아래 장기 단계는 아직 완료되지 않았다. 1.1절의 SwiftUI 로컬 알파가 부분 구현 상태를 설명한다.

| 단계 | 작업 산출물 | 완료 기준 / 실패 시 처리 |
|---|---|---|
| Phase 0: 실현성 검증 | iMessage·TDLib·암호화/FTS5·Tauri 패키징 spike 결과, SDK/OS 버전 고정, 결정 기록 | 각 기술이 대상 Mac에서 독립 실행되고 실패 조건 재현; 막힌 커넥터는 범위 축소 후 재계획 |
| Phase 1A: 골격 | Rust workspace, React UI, 합성 커넥터, migration, CI | 깨끗한 checkout에서 UI·코어 검증과 합성 인박스 실행 재현 |
| Phase 1B: 수신 알파 | 검증 통과한 iMessage·Telegram 연결, 저장, 페이지 조회, 필터, 연결 상태 | 재시작·잠자기·오프라인 복귀 후 테스트 데이터 누락/중복 없음; 수집 범위 표시 |
| Phase 2A: 검색/보관 | FTS, 삭제·수정 반영, 보관 설정, 권한 철회 UX | 검색·삭제·보관 테스트와 성능 목표 통과; 보안 저장 검증 완료 |
| Phase 2B: 답장 베타 | Telegram 발신 우선, iMessage 발신 spike 통과 후 추가, outbox | 중복 클릭·응답 유실·재시작 시 중복 발신 방지; unknown 상태 사용자 확인 |
| Phase 3: 커넥터 확장 | Slack 우선 검증; Discord 봇 모드; 나머지 11개 후보의 검증 기록 | 플랫폼별 기능표·인증·배포·복구 테스트를 통과한 것만 순차 제공; LINE/LinkedIn 포함 |
| Phase 4: 배포 안정화 | 서명·공증 DMG, 설치/업그레이드 검증, 라이선스 고지, 지원표 | 개발 환경 없는 Mac에서 실행; 실패한 migration의 복구 검증; 미검증 기능 표시 제거 |
| 후속: AI/업데이트 | 선택적 로컬 요약, 서명된 자동 업데이트 | 실제 모델 실행 장치·성능·권한 검증; NPU 가속 또는 무조건 자동 답장 약속 없음 |

Phase 3의 전체 플랫폼 구현은 첫 정식 배포의 선행 조건이 아니다. Phase 2까지 검증된 기능만으로 Phase 4를 진행할 수 있다.

## 8. 테스트·성능·빌드 계획

아래 표의 Tauri/Rust 명령은 아직 제공하지 않는다. 현재 SwiftUI 알파의 실행 가능한 명령은 루트 README와 native/README.md에 있다. Phase 1A에서 해당 인터페이스를 만들고 실제 성공 결과로 README를 갱신한다. Node LTS·Rust stable·패키지 관리자 및 네이티브 SDK의 정확한 버전은 Phase 0 결과에 맞춰 잠금 파일과 도구 버전 파일로 고정한다.

| 예정 명령 | 목적 |
|---|---|
| npm ci | 루트 package.json 및 lockfile 기반 설치 |
| npm run dev | 합성 데이터로 웹 UI 확인 |
| npm run tauri dev | macOS 앱 개발 실행 |
| npm run typecheck / npm run test / npm run build | 타입·UI 테스트·웹 빌드 |
| cargo fmt --all -- --check | Rust 형식 검사 |
| cargo clippy --workspace --all-targets -- -D warnings | 정적 검사 |
| cargo test --workspace | 코어·드라이버·migration 검증 |
| npm run tauri build | 대상 Mac용 앱/DMG 생성 |

공통 테스트: 원본 ID 충돌(서로 다른 계정), 중복/역순 이벤트, 편집·삭제 선행 도착, 부분 트랜잭션 실패, 커서 재개, 키 접근 실패, 암호화 DB 열기, 마이그레이션 실패 복구. 발신 테스트: 중복 클릭, 타임아웃 후 서버 성공, rate limit, 인증 만료. UI 테스트: 빈 인박스, 긴 텍스트, 한국어 검색, 첨부 전용, 키보드 탐색, 연결 오류, 미지원 기능 숨김.

실제 macOS 검증: 권한 거부·철회, 잠자기 복귀, 앱 재실행, 오프라인, DMG 설치, 서명 검증, 신규 설치와 이전 DB 업그레이드. 일반 CI에는 합성 데이터만 사용하고 사용자 chat.db·세션·인증정보는 올리지 않는다. 실제 계정 테스트는 별도 승인된 테스트 계정에서 수행한다.

성능은 보장값이 아닌 수용 목표다. 기준 기기는 Phase 0에서 모델·RAM·OS를 기록한다. 합성 텍스트 100,000건, 2계정, 첨부 다운로드 제외 조건에서 warm 검색 p95 200ms 이하, 로컬 이벤트 수신 후 화면 반영 p95 1초 이하, 유휴 CPU 평균 2% 이하, 전체 앱/sidecar 메모리 400MB 이하를 우선 목표로 한다. 검색은 최소 100개 혼합 질의, 유휴는 동기화 종료 후 10분 측정하고 cold 검색/초기 동기화는 별도 보고한다. 한국어 부분 검색 요구가 FTS 토큰화로 충족되는지 검증하고 미충족 시 토크나이저 전략을 다시 결정한다.

DMG 직접 배포는 다른 서비스의 권한·정책을 우회하는 근거가 아니다. 서명·공증은 실제 배포 파이프라인에서 검증하며 무조건 경고 없는 실행을 약속하지 않는다. 모든 포함 라이브러리와 sidecar의 라이선스·재배포 의무를 출시 체크에 포함한다.

## 9. 바로 다음 작업과 결정 기록

- [ ] P0-01: 대상 Mac/OS와 iMessage 테스트 데이터 범위 기록.
- [ ] P0-02: iMessage 읽기 권한·스키마·새 메시지·재시작 spike 결과 작성.
- [ ] P0-03: TDLib 로그인·2FA·수신·세션 재개·번들 spike 결과 작성.
- [ ] P0-04: 암호화 DB와 FTS5·WAL·migration·Keychain 연동 검증.
- [ ] P0-05: 최소 Tauri 앱의 Apple Silicon 패키징 검증 및 버전 고정.
- [ ] P0-06: 결과를 종합해 MVP 커넥터와 Phase 1 작업 목록 확정.

각 결정 기록은 문제, 대안, 선택, 검증 기기/버전, 재현 절차, 관찰 결과, 미해결 항목, 재검토 조건을 포함한다. 현재 SwiftUI 알파의 합성 테스트·패키징 결과만으로 실제 계정 검증 및 장기 Tauri 단계가 완료된 것으로 계산하지 않는다.

## 10. 확인한 공식 자료

2026-09-07 확인. 아래는 API/도구의 설명 근거이며 이 프로젝트에서 실제 연동에 성공했다는 의미는 아니다.

- [Discord: Automated User Accounts (Self-Bots)](https://support.discord.com/hc/en-us/articles/115002192352-Automated-User-Accounts-Self-Bots): 일반 사용자 계정 자동화 제한; 개인 DM 통합을 초기 필수 조건에서 제거한 근거.
- [Slack Events API](https://docs.slack.dev/apis/events-api/): 이벤트 수신은 OAuth scope와 접근 가능한 대화에 종속.
- [TDLib 시작 안내](https://core.telegram.org/tdlib/getting-started): 클라이언트 구성과 애플리케이션 인증 정보 준비.
- [Tauri Capabilities](https://tauri.app/security/capabilities/): 창/WebView에 허용할 명령과 권한 범위를 설계하는 근거.
