# Synapse native app — 0.3.3

Telegram integration is documented in [TELEGRAM.md](TELEGRAM.md). The current binary targets Apple Silicon/macOS 26+. API credentials stay in Keychain; personal data stays outside Git.

# Synapse native local alpha

2026-09-07 · 0.2.7 · Apple 메시지 읽기·텍스트/사진 전송 macOS 앱.

이번 구현은 바로 설치 가능한 DMG로 iMessage의 실현성을 확인하기 위한 SwiftUI 독립 앱이다. 기존 계획의 Tauri/Rust 멀티플랫폼 통합 앱을 완성한 것은 아니다. 개발 환경에 Rust/Cargo가 없고 Apple Swift 도구가 있어 최초 로컬 테스트 경로로 선택했다. 장기 UI/코어 선택은 실제 메시지 테스트 후 재검토한다.

## 구조

- `Sources/MessageStore.swift`: SQLite 읽기 전용 접근, 제한된 typedstream 본문 해독, 메시지 정규화.
- `Sources/ContactNames.swift`: Contacts 권한·전화번호/이메일 일치 조회, 이름·이니셜 표시. 중복 이름은 합치고 다른 저장 이름은 함께 표시.
- `Tests/ContactTests.swift`: 합성 연락처로 이름·검색·권한·캐시·연결 해제 검증.
- `Sources/PhotoFile.swift`: 선택 사진 형식·20 MiB 한도·SHA-256 검증. 원본을 복사하거나 변환하지 않는다.
- `Sources/OutgoingPhotoPreview.swift`: 전송할 사진 미리보기·취소.
- `Tests/PhotoTests.swift`: 사진 선택·대화별 상태·전송 인수·오류·실제 helper 사전 검증.
- `Sources/MessageComposer.swift`: NSTextView 기반 작성창, Enter 전송·Shift+Enter 줄바꿈, IME 조합 중 전송 방지.
- `Sources/AttachmentPreview.swift`: ImageIO 축소 이미지 표시·확대, 로컬 첨부 경로 검사.
- `Tests/ComposerImageTests.swift`: 키 이벤트·조합 보호·이미지 디코딩·경로 제한 검사.
- `Sources/SynapseApp.swift`: SwiftUI 대화/검색/작성창/권한 안내.
- `Sources/InboxModel.swift`: 비동기 조회, 연결 상태, 대화별 초안, 중복 전송 방지와 결과 상태. 여러 창이 하나의 모델을 공유한다.
- `Sources/SendTypes.swift`: 전송 요청 검증, 고정 AppleScript, 문자열 Apple event 인수.
- `Sources/MessageSender.swift`, `SenderHelper.swift`: 표준입력 JSON으로 통신하는 별도 전송 프로세스. UI를 막지 않고 45초 제한으로 결과를 처리한다. 본문·대상은 명령행 인수나 임시 파일에 쓰지 않는다.
- `Tests/SendTests.swift`: 합성 전송기와 프로세스 stub으로 발신 상태·오류·인수 보존 검증. 실제 전송하지 않는다.
- `Tests/StoreTests.swift`: 임시 합성 DB와 Apple NSArchiver로 만든 테스트 본문. NSArchiver는 fixture 생성에만 사용한다. 앱에는 객체 역직렬화 코드를 포함하지 않는다.
- `scripts/build.sh`: 앱 번들 생성, 아이콘 생성, ad-hoc 코드 서명 및 검증.
- `scripts/test.sh`: 네이티브 데이터 계층 검증.
- `scripts/package.sh`: 장치를 마운트하지 않고 HFS 이미지 생성 후 UDZO DMG 변환·검증.
- `INSTALL.md`: 사용자 설치 방법, 검증 결과 및 한계.

## 재현

필요 도구: Apple Silicon Mac, Xcode/Command Line Tools의 Swift 컴파일러, macOS 기본 hdiutil/codesign. 외부 패키지 다운로드가 없다. 검증 환경: Swift 6.3.3, macOS 26.6.2. 최소 배포 대상 macOS 13은 실기기 검증 전이다.

프로젝트 루트에서:

```sh
bash native/scripts/test.sh
bash native/scripts/build.sh
bash native/scripts/package.sh
```

기본 결과: `native/build/Synapse.app`, `native/build/Synapse-0.2.10-arm64.dmg`. 각 스크립트의 첫 인수로 별도 빌드 디렉터리를 지정할 수 있다. 패키징은 먼저 앱을 빌드한다.

## 구현 상태

P0-02의 합성 데이터 읽기/본문 해독과 P0-05의 SwiftUI 대체 경로 패키징을 수행했다. 실제 개인 DB의 서비스 분류와 기존 RCS/iMessage 대상 조회는 읽기 전용으로 확인했다. 권한 철회·잠자기/재연결은 아직 미검증이며 iMessage 전체 지원 완료로 표시하지 않는다. 기존 iMessage·SMS·RCS 대화에 텍스트 발신을 구현했으며 실제 계정 발신은 미검증이다. Telegram·암호화 검색 저장소·15개 서비스 구현은 포함하지 않는다.

메시지를 디스크에 복제하지 않는 메모리 조회 방식이다. SQLite가 WAL 읽기에 필요한 공유 메모리 잠금을 사용할 수 있으므로 원본 디렉터리 전체의 바이트 불변까지 보장하지 않는다. DB를 immutable로 열거나 원본에 checkpoint를 실행하지 않는다.

제품 UI는 읽기 권한을 필요 시 안내한다. 기본 샘플에서 실제 DB를 자동으로 열지 않는다. 실제 전송은 기본 메시지 연결에서만 가능하며, 파일 선택으로 불러온 DB에서는 차단한다. 전송 도구는 고정된 메시지 전송 계약만 받는다. 알 수 없는 본문은 추측해 표시하지 않고 미지원으로 표시한다.

## 전송 계약과 한계

기존 iMessage·SMS·RCS 대화의 GUID를 대상으로 한다. `any;-;…`/`any;+;…`는 `chat.service_name`이 iMessage, SMS 또는 RCS일 때 전송을 허용한다. 해당 서비스 접두어를 가진 기존 GUID도 지원한다. 서비스 불명 대화는 차단한다. 메시지 앱에서 정확히 같은 ID의 대화를 확인한 후 `send`를 호출한다. RCS/SMS 전달 계정은 사용 가능한 대화에서도 비활성 상태로 표시될 수 있어 계정의 enabled/connection status로 발신을 차단하지 않는다. 캐시된 서비스 이름으로 다른 수신자나 계정을 선택하지 않는다. 실제 전송 경로와 RCS/SMS 전환은 Apple 메시지 앱이 처리한다. 본문은 UTF-8 16,384바이트 이내이며 공백만 있는 본문과 NUL은 거절한다.

`accepted`는 Apple 메시지 앱의 send 명령 반환을 의미하며 배달 확인이 아니다. 발신 명령 이후 오류·타임아웃·프로세스 중단은 `unknown`으로 취급하고 자동 재전송하지 않는다. 결과 불명인 대화는 사용자가 메시지 앱에서 확인했다고 표시할 때까지 재전송을 막는다. 초안과 결과는 메모리 전용이며 재시작 시 복원하거나 발신하지 않는다. 시스템 재시작·네트워크 장애를 넘는 영속 outbox와 배달 확인은 후속 범위다.

별도 프로세스에서 NSAppleScript를 주 스레드로 실행한다. [Apple NSAppleScript 문서](https://developer.apple.com/documentation/foundation/nsapplescript)에 따른 handler 호출로 문자열 인수를 전달한다. 앱에 [자동화 사용 설명](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)과 Apple Events entitlement를 포함한다. 실제 TCC 권한 귀속·승인/거부/철회와 개인 계정 전송은 설치 후 사용자 검증 항목이다.

helper의 `--check-target` 모드는 전송 대상만 확인하고 `send` 전에 반환한다. 입력은 일반 전송과 같은 JSON이며 본문은 발신하지 않는다. 실제 계정으로 이 모드가 성공해도 배달 성공을 의미하지 않는다.

## 0.2.3 연락처와 화면 정리

연락처 접근은 실제 메시지 연결 후 첫 DB 조회가 성공했을 때 한 번 요청한다. 거부한 권한은 설정 버튼으로 안내하며 주기적 새로고침 때 재요청하지 않는다. 권한이 있으면 불러온 대화의 전화번호·이메일에 해당하는 이름만 조회해 메모리에 캐시한다. Contacts의 일치 검색을 사용하며 번호 뒤쪽 자릿수로 임의 추정하지 않는다. 그룹 이름과 명시된 업체 이름은 유지한다. 앱 활성화·연락처 변경 시 캐시를 갱신하며 연결 해제 시 비운다. 가져온 DB는 개인 연락처를 조회하지 않는다.

대화 제목·원형 이니셜·그룹 발신자와 검색에 이름을 적용하되 전송 GUID와 초안 키는 유지한다. 작성창 위의 내부 ID·중복 수신자 안내를 제거하고 성공 상태는 짧은 ‘전송 요청됨’으로 표시한다. 오류와 결과 불명 안내는 필요한 경우에 표시한다.

읽기 29개, 전송 54개, 연락처 25개 검사(총 108개) 통과. 합성 연락처를 사용하는 macOS 미리보기에서 이름·이니셜·작성창과 전송 완료 표시를 확인했다. 실제 Contacts 권한 승인 및 사용자 연락처 일치 여부는 설치 후 확인 대상이다.

## 0.2.4 입력과 첨부 이미지

Enter·키패드 Enter는 전송하며 Shift+Enter는 줄바꿈한다. 입력기 조합 중 Return은 입력기로 넘기며 키 반복은 전송하지 않는다. 붙여넣은 줄바꿈도 전송으로 해석하지 않는다. 전송 가능 여부는 기존 모델 검사를 따른다.

attachment/message_attachment_join에서 로드된 메시지의 첨부 메타데이터를 읽고 중복 조인을 제거한다. 실제 메시지 연결에서만 이미지 파일을 읽는다. 경로는 symlink를 해소한 Messages/Attachments 내부의 일반 파일로 제한한다. 최대 50 MiB 파일을 ImageIO로 최대 1,400픽셀까지 축소해 메모리에 표시하며 별도 복사·네트워크 다운로드는 하지 않는다. GIF·다중 이미지 형식은 첫 프레임 미리보기이며 실제 지원 코덱은 시스템 ImageIO에 따른다. 가져온 DB는 이미지 메타데이터만 표시한다. 미다운로드·손상·권한 부족은 재시도 안내로 처리한다.

최신 검증: 읽기 35개·전송 54개·연락처 25개·입력/이미지 16개(총 130개) 통과. 합성 macOS 화면에서 Shift+Enter 두 줄 입력, Enter 전송·초안 비움, 이미지 말풍선과 클릭 확대를 확인했다. 실제 개인 계정 발신·첨부 파일 접근과 다른 OS는 별도 확인 대상이다.

## 0.2.5 연락처 연결·링크 썸네일·한 줄 입력

실행 중인 0.2.4에서 연락처 상태가 아직 notRequested였음을 UI로 확인했다. 실제 연결의 첫 조회 성공 시 Contacts 요청을 실행하도록 바꿨다. 실제 허용은 사용자가 macOS 창에서 수행한다.

공유 링크 이미지는 MIME이 없고 .pluginPayloadAttachment 확장자여도 ImageIO로 디코딩한다. payload_data의 property list를 객체 생성 없이 읽고 RichLink의 제목과 주 이미지 대체 인덱스를 찾아 favicon·내부 파일명 대신 대표 이미지를 표시한다. 아카이브 크기·객체 수·인덱스는 제한하고 외부 URL 다운로드는 수행하지 않는다. 제공된 Threads 링크의 실제 로컬 캐시에서 제목·주 이미지 인덱스 1을 확인했으며 1024×939 이미지 디코딩에 성공했다. 개인 데이터는 테스트 fixture나 배포 ZIP에 넣지 않았다.

작성창은 32pt 한 줄로 시작해 텍스트 배치 높이에 맞춰 최대 120pt까지 확장하며 이후 스크롤한다. 작성 내용이 비면 다시 줄어든다. Enter/Shift+Enter·IME 보호는 유지한다.

최신 검증: 읽기 40개·전송 54개·연락처 26개·입력/이미지 21개(총 141개). 합성 UI의 링크 카드, 한 줄→두 줄 확장, Enter 전송 후 한 줄 복원을 확인했다. 실제 Contacts 승인·일치 및 실제 발신은 사용자 확인 대상이다.

## 0.2.6 중복 연락처와 첨부 표시 문자

Mac 연락처 앱의 전체 연락처 검색에서 제공된 두 번호에 각각 2개 레코드가 있음을 확인했다. 하나는 같은 이름의 중복, 다른 하나는 언어가 다른 두 저장 이름이었다. 기존 contacts.count == 1 조건도 중복 결과의 이름을 숨길 수 있어 제거했다. 이 변경만으로 실제 사용자 대화의 이름 문제는 해결되지 않았으며 0.2.8에서 Messages 참가자 이름 조회를 추가했다. 이제 결과의 표시 이름을 정리·중복 제거하고 다른 이름은 /로 함께 표시한다. 연락처 원본이나 전송 대상을 변경하지 않는다.

LG Electronics USA·Wayfair의 실제 로컬 메시지 본문에서 U+FFFE와 첨부 1개를 확인했다. FFFC·FFFE·FFFF 내부 표시 문자를 제거하되 일반 물음표, U+FFFD, 캡션·이모지는 유지한다. 미디어 전용 메시지는 목록에 첨부파일로 표시한다. 최신 검사 150개 통과.

## 0.2.7 사진 전송

현재 Messages.sdef의 send 직접 인수가 file/text를 모두 지원함을 로컬에서 확인했다. 기존 정확한 chat ID를 유지하고 사진 경로를 Apple event 문자열로 넘긴 뒤 POSIX file as alias로 만들어 send한다. 원본 DB에는 쓰지 않는다.

사진은 한 장씩 전송한다. 요청은 텍스트 또는 사진 중 하나만 포함하며 작성 중인 글은 사진 성공 후에도 보존한다. 사진 선택·전송 동안 중복 작업과 연결 전환을 막는다. 파일 형식·최대 20 MiB·픽셀 수를 검사하고 선택 시 SHA-256을 기록하며 모델과 helper에서 다시 확인한다. 원본 이동·변경은 전송 전에 오류로 처리한다. 파일 경로·본문은 명령행이나 로그에 넣지 않으며 선택 사진 복사본을 별도로 저장하지 않는다. 파일은 메시지 앱이 읽으므로 실제 전달이 확인될 때까지 원본을 유지해야 한다.

샘플 사진은 실제 sender를 호출하지 않고 선택한 로컬 파일만 미리보기한다. 가져온 DB는 사진 선택·전송을 막는다. 오류·결과 불명은 선택을 유지하고 자동 재시도하지 않는다. unknown은 사용자의 확인 전 재전송을 차단한다. 실제 RCS 대화와 합성 PNG 파일로 production helper의 --check-target 검사가 ready를 반환했다. 실제 send·배달은 수행하지 않았다.

검증: 읽기 44개·텍스트 전송 54개·연락처 31개·입력/이미지 21개·사진 전송 24개(총 174개). 합성 UI 파일 선택·사진 미리보기·전송 후 사진 해제·글 보존 확인.

## 0.2.8 Messages 참가자 이름

사용자가 지적한 실제 두 대화는 chat.display_name이 비어 있고, 기존 Contacts 경로는 이름을 반환하지 않았다. Messages.sdef의 participant.full name은 두 대화 모두 메시지 앱 화면과 같은 한국어·영어 이름을 반환했다. 별도 읽기 전용 SynapseNames helper를 추가해 정확한 direct chat ID와 participant.handle을 확인한 뒤 이 이름을 우선 사용한다. Contacts는 보조 경로이고 업체·그룹의 명시 이름은 유지한다. 발신 코드와 전송 GUID에는 영향을 주지 않는다.

최대 24개 ID씩 Apple event 인수로 전달하며 고정 AppleScript만 실행한다. 결과를 파이프 실행 중 읽어 큰 응답의 교착을 막고, 시간·크기를 제한한다. 이름은 메모리에만 보관하며 60초 캐시와 활성화/연락처 변경 갱신을 사용한다. 연락처 권한 거부와 독립적으로 기존 Messages 자동화 권한을 사용하며 자동화 거부는 설정 버튼으로 표시한다. 샘플·가져온 DB는 조회하지 않고, 연결 해제 뒤 늦은 결과는 무시한다.

읽기 44·전송 54·Contacts 31·메시지 이름 29·입력/이미지 21·사진 24, 총 203개 검사 통과. production helper에서 사용자의 두 실제 대화 이름을 확인했다. 개인 자료는 테스트나 배포 파일에 포함하지 않는다.

설치된 /Applications/Synapse.app 0.2.8의 실제 연결 화면에서 사용자 스크린샷의 두 참가자 이름과 선택 대화의 상단 제목을 확인했다. 업데이트 전 44개 대화의 초안이 없음을 확인했고 이전 앱은 native/build/app-backups에 보관했다. 앱 교체 후 기존 Full Disk Access가 꺼져 같은 앱에 다시 적용했다. 메시지·사진 발신은 수행하지 않았다.

## 0.2.9 대화별 기록과 영어 UI

MessageStore.load에 매개변수화된 conversationID·beforeRowID 조회를 추가했다. 같은 ROWID 정렬과 배타적 커서로 1,000개씩 읽고 추가 한 행으로 다음 페이지 유무를 확인한다. 첨부도 같은 범위에서 읽으며 공유·중복 chat join은 대상 대화에 한정한다. 날짜가 같거나 새 메시지가 추가돼도 페이지가 겹치거나 건너뛰지 않는다.

선택 대화의 페이지는 메모리에 보관하고 최근 snapshot과 메시지 ID로 합친다. 자동 새로고침은 최근 범위의 편집·삭제를 반영하면서 오래된 페이지를 유지한다. 오류는 기존 메시지·커서를 보존해 재시도하며 연결 해제 후 늦은 결과는 버린다. 가져온 DB도 자체 과거 기록을 읽지만 발신과 개인 이름 조회는 차단한다.

검색은 목록 필터와 말풍선 강조·일치 항목 이동에 적용하고 전체 대화 흐름을 제거하지 않는다. UI·접근성·권한·오류·샘플은 영어이며 사용자 메시지·연락처 이름은 변환하지 않는다. 사용자 요청에 따라 수동 이름 지정 기능은 포함하지 않는다.

224개 자동 검사 통과. production reader와 설치 앱 양쪽에서 실제 긴 대화의 첫 페이지부터 마지막 페이지까지 중복 없이 로딩됨을 확인했다. 영어 UI, 검색어가 있는 상태의 주변 메시지와 링크 썸네일, 이름/미등록 번호 유지도 실제 화면에서 확인했다. 개인 메시지·첨부는 배포 파일에 포함하지 않는다.

## 0.2.10 상태줄 높이 고정

입력창 하단 들썩임을 조사해 조건부 ProgressView가 footer의 높이를 37→40→37pt로 바꾸는 것을 production SwiftUI view 측정으로 재현했다. InboxStatusBar로 분리하고 spinner 자리를 항상 16×16pt로 유지한다. 상태 문구를 한 줄로 유지해 폭이 좁거나 숫자가 길어져도 높이가 변하지 않는다. 폰트나 실제 입력 동작은 바꾸지 않는다.

폭 540·800·1,100pt에서 각각 새로고침 상태 40회 전환, 긴 카운터, 샘플과 가져온 DB 상태를 검사했다. 수정 후 높이는 모두 40pt. 기존 검사와 합쳐 239개 통과.
