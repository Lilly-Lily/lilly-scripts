# WW-Tappo-Mouse-Move-Patch

WuwaTappo(데스크톱 펫)의 마우스 이동 처리 부하를 줄이는 1바이트 패치 도구임. 마우스 폴링률이 높을 때(2000Hz 이상) 시스템 전체가 느려지는 문제를 줄이기 위한 것임.

WuwaTappo는 마우스가 움직일 때마다 이동 이벤트를 만들어 앱 화면 쪽으로 전달함. 이 처리량이 폴링률에 비례해 늘어나므로, 이 도구는 **이동 이벤트만** 전달되지 않게 바꿈. 클릭, 휠, 키보드 이벤트는 그대로 유지됨.

> [!WARNING]
> 이 도구는 `WuwaTappo.exe`를 직접 수정함. 사용 전에 [면책 조항](#면책-조항)을 반드시 읽을 것.

## 주요 기능

- `WuwaTappo.exe` 안의 마우스 이동 이벤트 변환 부분을 1바이트 수정
- 패치 전 원본을 `.bak`으로 백업
- 원본으로 되돌리기(`Restore`) 지원
- 현재 상태만 확인(`Check`)하는 읽기 전용 모드 지원
- 패치 위치를 코드 패턴으로 찾으며, 확정할 수 없으면 아무것도 바꾸지 않고 중단

## 요구 사항

- Windows 10 / 11, Windows PowerShell 5.1 이상
- 관리자 권한 (`C:\Program Files` 안의 파일을 수정하므로 실행 시 권한 확인창이 뜸)
- 테스트된 버전: WuwaTappo `v1.0.3` (`WuwaTappo.exe` SHA256 `E872582D245A76B58737D4C281B7D62E22DF7BEB91B3E312FCE31448A23AB5E6`, 2026-10-29 빌드)

## 사용법

1. 인터넷에서 받은 zip이라면 압축을 풀기 전에 파일 속성에서 **차단 해제**를 체크함.
2. 압축을 풀고 `Check-MouseMove.cmd`를 실행해 `상태: 원본 (... 적용 가능)`이 나오는지 확인함.
3. `Patch-MouseMove.cmd`를 실행함. 관리자 권한 확인창을 허용하면 WuwaTappo가 종료된 뒤 패치되고 다시 실행됨.
4. 되돌릴 때는 `Restore-MouseMove.cmd`를 실행함.

설치 경로가 기본값(`C:\Program Files\WuwaTappoGlobal`)과 다르면 다음처럼 경로를 지정함.

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WuwaTappo-MouseMove.ps1 -Mode Patch -AppPath "D:\...\WuwaTappo.exe"
```

## 구성 파일

| 파일 | 역할 |
| --- | --- |
| `WuwaTappo-MouseMove.ps1` | 패치 / 복원 / 확인 본체 (`-Mode Patch`, `Restore`, `Check`) |
| `Patch-MouseMove.cmd` | 패치 실행용 |
| `Restore-MouseMove.cmd` | 복원 실행용 |
| `Check-MouseMove.cmd` | 상태 확인용 |

실행 중 만들어지는 `WuwaTappo.exe.mousemove-original.<해시>.bak`(원본 백업)은 설치 폴더에 생기며 저장소에는 포함하지 않음.

## 동작 원리

1. `WuwaTappo.exe`를 읽어 마우스 이동 이벤트 변환 코드(32바이트 패턴)를 찾음.
2. 패턴이 원본 1곳이면 적용 가능, 패치된 1곳이면 이미 적용됨, 그 외에는 알 수 없음으로 판단하고 중단함.
3. 패치 시 실행 중인 같은 경로의 `WuwaTappo.exe`를 종료하고 원본을 백업함.
4. 이동 이벤트의 종류 값 `0x04`(MouseMove)를 `0x06`(이벤트 없음)으로 1바이트 바꾸고 결과를 다시 검사함.
5. 종료했던 경우 `WuwaTappo.exe`를 다시 실행함.

## 사용 시점과 주의할 점

- 앱이 업데이트되면 `WuwaTappo.exe`가 새 파일로 교체되어 패치가 풀림. `Patch-MouseMove.cmd`를 다시 실행하면 됨. 코드가 바뀌어 패턴을 못 찾으면 아무것도 바꾸지 않고 중단함.
- 패치하면 `WuwaTappo.exe`의 전자서명 검증이 유효하지 않게 됨. 보안 프로그램이 경고할 수 있음.
- 마우스 이동에 반응하는 기능(펫이 커서를 따라 움직이는 동작 등)이 있다면 멈출 수 있음. 이 경우 `Restore`로 되돌릴 것.
- 마우스 폴링률을 낮추는 것도 부하를 줄이는 방법임. 이 도구와 별개로 함께 쓸 수 있음.

## 면책 조항

- 이 도구는 개인이 만든 비공식 도구이며, WuwaTappo 제작사 및 게임 `명조(Wuthering Waves)`와 관련이 없음. 이름과 상표는 각 소유자의 것임.
- `WuwaTappo.exe` 1바이트만 수정하며, 게임 클라이언트와 게임 파일은 건드리지 않음. 프로그램 파일은 이 저장소에 포함되어 있지 않음.
- 관리자 권한으로 실행 파일을 수정하므로, 실행 전에 스크립트 내용을 직접 확인할 것을 권장함.
- 이 도구의 사용으로 생기는 프로그램 오작동, 데이터 손실, 약관상 불이익 등 어떠한 결과에 대해서도 작성자는 책임지지 않음. 사용에 따른 책임은 사용자에게 있음.

## 라이선스

[MIT License](../LICENSE)
