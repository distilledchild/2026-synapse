# Synapse 0.2.0 로컬 알파

기존 iMessage 대화에 텍스트 작성·전송을 추가했습니다.

- [Apple Silicon 설치 DMG](Synapse-0.2.0-arm64.dmg)
- [설치·권한·전송 안내](Synapse-local-test-guide.md)
- [소스 ZIP](Synapse-0.2.0-source.zip)
- [SHA-256 체크섬](Synapse-0.2.0-SHA256.txt)

읽기 26개·전송 39개 검사와 실제 앱의 샘플 작성·전송 UI 검증을 통과했습니다. 앱·helper 코드 서명 및 DMG 무결성을 확인했습니다. 실제 계정 발신·배달과 macOS 권한 승인·거부·철회는 사용자 테스트가 필요합니다. Apple Developer ID 서명·공증은 없는 개인 테스트판입니다.

새 대화·SMS/RCS 발신·첨부 전송·수정·삭제는 지원하지 않습니다. 초안은 앱 종료·연결 해제 시 지워집니다.
