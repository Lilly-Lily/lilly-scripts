# lilly-scripts

명조(Wuthering Waves)와 Windows PC 관리를 위해 만든 개인 스크립트 모음.

모든 도구는 Windows PowerShell 5.1 기반이며, 도구마다 폴더가 따로 있음. 자세한 사용법은 각 폴더의 README 참고.

> [!WARNING]
> 개인이 만든 비공식 도구이며, 사용에 따른 책임은 사용자에게 있음.
> 자세한 내용은 각 도구 README의 면책 조항 참고.

## 명조 도구

| 도구 | 설명 | 관리자 권한 |
| --- | --- | --- |
| [WW-Cache-Cleaner](WW-Cache-Cleaner/) | 다중 클라이언트용 셰이더 캐시 정리 (게임·그래픽 드라이버·DirectX·Steam) ([Release](https://github.com/Lilly-Lily/lilly-scripts/releases/tag/WW-Cache-Cleaner-v1.0)) | 필요 |
| [WW-IMG-QuickEdit](WW-IMG-QuickEdit/) | 스크린샷 UID 자동 가리기, 크롭·리사이즈·포맷 변환 | 필요 없음 |
| [WW-INI-Manager](WW-INI-Manager/) | 클라이언트별 `Engine.ini` 백업·삭제·이식·복원 | 필요 없음 (설치 위치에 따라 필요) |
| [WWMI-DX12-Toggle](WWMI-DX12-Toggle/) | WWMI-DX12 파일을 백업 폴더로 이동하거나 복원하여 작동을 끄고 켜기 ([Release](https://github.com/Lilly-Lily/lilly-scripts/releases/tag/WWMI-DX12-Toggle-v1.0)) | 필요 없음 (설치 위치에 따라 필요) |

## 일반 도구

| 도구 | 설명 | 관리자 권한 |
| --- | --- | --- |
| [HashTool](HashTool/) | 파일·폴더 해시 조회·저장·비교·검증 | 필요 없음 |
| [Key-Input-Tracer](Key-Input-Tracer/) | 키 입력이 실제 키보드인지 다른 프로그램이 주입한 것인지 구분해 기록 | 필요 없음 |

## 공통 요구 사항

- Windows 10 / 11
- Windows PowerShell 5.1 (Windows 기본 포함, 추가 설치 없음)

## 공통 사용법

1. 이 저장소를 받거나(**Code → Download ZIP**) 필요한 도구 폴더만 받음.
2. 인터넷에서 받은 파일은 Windows가 차단할 수 있으므로, 압축을 풀기 전에 zip 파일 **속성 → 차단 해제**를 체크함.
3. 각 폴더의 `.bat` 파일을 실행함.

## 라이선스

[MIT License](LICENSE)
