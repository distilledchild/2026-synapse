# Synapse 0.2.1

현대 macOS의 `any;…` 대화 ID를 iMessage로 인식하지 못해 작성창이 숨겨지던 오류를 수정했습니다. `chat.service_name`을 읽어 작성 가능 여부를 판별합니다.

- [설치 DMG](Synapse-0.2.1-arm64.dmg)
- [설치·사용 안내](Synapse-local-test-guide.md)
- [소스 ZIP](Synapse-0.2.1-source.zip)
- [체크섬](Synapse-0.2.1-SHA256.txt)

읽기 29개·전송 46개 검사 통과. 실제 로컬 DB를 읽은 모델 검사에서 불러온 iMessage 대화 10개의 작성 가능 상태와 SMS/RCS 32개의 발신 차단을 확인했습니다. 실제 메시지 발신은 수행하지 않았습니다. 앱 서명·DMG 무결성 검증을 통과했습니다.

실행 중인 Synapse를 종료하고 Applications의 앱을 교체한 뒤 다시 연결하세요. 개인 테스트용 ad-hoc 서명이며 Developer ID 서명·공증은 없습니다.
