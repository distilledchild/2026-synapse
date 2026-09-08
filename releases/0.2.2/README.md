# Synapse 0.2.2

RCS·SMS 기존 대화에도 작성창과 전송을 제공합니다. Apple 메시지 앱의 비활성 계정 플래그로 정상 대화의 전송을 잘못 막던 검사도 제거했습니다. 정확한 기존 대화 ID로 발신하며 다른 수신자나 계정으로 대체하지 않습니다.

- [설치 DMG](Synapse-0.2.2-arm64.dmg)
- [사용 안내](Synapse-local-test-guide.md)
- [소스 ZIP](Synapse-0.2.2-source.zip)
- [SHA-256](Synapse-0.2.2-SHA256.txt)

읽기 29개·전송 54개 검사 통과. 실제 로컬 DB에서 iMessage 10개, SMS 26개, RCS 6개 대화의 작성 및 요청 가능 상태를 확인했습니다. 사용자 화면의 RCS 대화와 이전 iMessage 대화는 실제 Apple 메시지 앱의 읽기 전용 대상 검사에서 ready를 반환했습니다. 실제 메시지 발신·배달은 수행하지 않았습니다.

Synapse를 완전히 종료하고 Applications의 앱을 교체한 뒤 메시지 연결을 누르세요. 개인 테스트용 ad-hoc 서명이며 Developer ID 서명·공증은 없습니다.
