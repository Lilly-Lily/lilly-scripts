# WWMI-DX12-Toggle

명조(Wuthering Waves)의 `Win64` 폴더에 설치한 **WWMI-DX12** 파일을 백업 폴더로 옮겼다가 다시 되돌리는 Windows용 도구.

파일을 삭제하지 않고 이동만 하므로, DX11 WWMI나 순정 상태로 실행하고 싶을 때 WWMI-DX12를 지웠다 다시 설치하는 과정 없이 메뉴에서 키 한 번으로 껐다 켤 수 있음. 명조 설치 경로는 자동으로 찾아주고, 직접 입력해서 바꿀 수도 있음.

> [!WARNING]
> 게임 폴더의 파일을 이동하는 도구임. 사용 전에 [면책 조항](#면책-조항)을 꼭 읽어볼 것.

## 주요 기능

- **Off**: `Win64`의 WWMI-DX12 파일을 백업 폴더로 이동
- **On**: 백업 폴더의 파일을 `Win64`로 복원
- **상태 표시**: `Win64`와 백업에 각각 어떤 항목이 있는지 보여주고 현재 상태(On / Off)를 판정
- **ReShade 세트 포함 여부 전환**: `dxgi.dll` 등 ReShade 파일을 함께 옮길지 메뉴에서 선택
- **명조 경로 자동 탐색 / 변경**: Steam 라이브러리 등에서 설치 경로를 찾아 번호로 선택하게 하고, 직접 입력도 지원

## 요구 사항

- Windows 10 / 11
- Windows PowerShell 5.1 (Windows에 기본 포함)
- 명조 클라이언트와 WWMI-DX12가 이미 설치되어 있어야 함 (이 도구는 설치 기능이 없음)
- 관리자 권한은 보통 필요 없음. 게임이 `Program Files` 같은 보호된 폴더에 있어서 이동에 실패하면 그때만 관리자 권한으로 실행

## 사용법

1. [Releases](https://github.com/Lilly-Lily/lilly-scripts/releases/tag/WWMI-DX12-Toggle-v1.0)에서 `WWMI-DX12-Toggle-v1.0.zip`을 받아 압축을 풀고, 안의 파일(`wwmi_dx12_toggle.bat`, `wwmi_dx12_toggle.ps1`)을 아무 곳에나 둠.
2. 인터넷에서 받은 파일이면 두 파일 각각 우클릭 → 속성 → 하단의 **차단 해제**에 체크 후 확인.
3. **게임을 완전히 종료**한 상태에서 `wwmi_dx12_toggle.bat`을 실행.
4. 처음 실행하면 명조 경로를 고르는 화면이 나옴. 번호를 입력해서 선택하거나 마지막 번호(직접 입력)를 골라 경로를 붙여넣음.
5. 메뉴에서 키를 누름.

### 메뉴

| 키 | 동작 |
| --- | --- |
| `1` | **Off**: WWMI-DX12를 백업 폴더로 옮김 |
| `2` | **On**: 백업에서 `Win64`로 되돌림 |
| `3` | 명조 경로 변경 |
| `4` | ReShade 포함 여부 전환 (포함 ↔ 제외) |
| 그 외 | 아무것도 하지 않고 닫기 |

### 인자로 바로 실행

메뉴 없이 바로 실행하려면 bat에 인자를 붙임.

```
wwmi_dx12_toggle.bat Off
wwmi_dx12_toggle.bat On
wwmi_dx12_toggle.bat Status
```

## 경로 선택

처음 실행할 때와 메뉴 `3`에서 아래와 같은 화면이 나옴.

```
WWMI-DX12 가 설치된 명조 경로를 선택해 주세요.
  [1] C:\Wuthering Waves\Wuthering Waves Game\Client\Binaries\Win64  (현재)
  [2] D:\SteamLibrary\steamapps\common\Wuthering Waves\Client\Binaries\Win64
  [3] 직접 입력
  [0] 취소
```

- 자동으로 찾은 경로가 1번부터 차례로 나오고, 마지막 번호가 **직접 입력**임. 못 찾으면 직접 입력만 나옴.
- 직접 입력은 탐색기 주소창에서 복사한 경로를 그대로 붙여넣으면 됨. 따옴표가 붙어 있어도 됨.
- 입력 경로는 아래 중 어느 것이든 인식함. 입력한 폴더 안에서 `Client-Win64-Shipping.exe`가 있는 `Win64` 폴더를 찾아냄.
  - `...\Wuthering Waves`
  - `...\Wuthering Waves\Wuthering Waves Game`
  - `...\Client\Binaries\Win64`
- 자동 탐색은 Steam 설치 경로와 `libraryfolders.vdf`에 적힌 라이브러리, 그리고 각 드라이브의 흔한 설치 위치(`Wuthering Waves`, `Games\Wuthering Waves`, `Program Files\Wuthering Waves`)를 확인함.
- `0`을 고르면 취소됨. 변경 중이면 기존 경로가 유지되고, 첫 실행이면 도구가 종료됨.

고른 경로는 `wwmi_dx12_toggle.cfg`에 저장되어 다음 실행부터는 묻지 않음. 저장된 경로가 사라지거나 틀려지면 자동으로 다시 물음.

## 옮기는 대상

| 대상 | 설명 |
| --- | --- |
| `wwmi_dx12*` | `wwmi_dx12.addon64`, `wwmi_dx12` 폴더, `wwmi_dx12.ini`, 실행 bat/ps1, 로그 등 이름이 `wwmi_dx12`로 시작하는 모든 항목 |
| `dxgi.dll`, `ReShade.ini`, `ReShadePreset.ini`, `ReShade.log`, `reshade-shaders` | ReShade 세트. **포함** 설정일 때만 옮기며, 있는 것만 옮김 |
| `ReShade.ini`의 `[ADDON] AddonPath`에 복사된 `wwmi_dx12.addon64` | `AddonPath`가 `Win64` 밖의 폴더로 지정된 경우 그 폴더의 addon64도 함께 백업하고, On 때 원래 위치로 복원 |

게임 실행 파일(`Client-Win64-Shipping.exe` 등)과 그 밖의 게임 파일은 건드리지 않음.

### ReShade 포함 여부

- **포함**(기본값): ReShade 세트도 함께 백업됨. DX11용 XXMI 런처가 자체 경로의 ReShade를 따로 주입하는 환경에서, `Win64`에 남은 `dxgi.dll`과 이중으로 로드되는 것을 피하고 싶을 때 사용.
- **제외**: ReShade 세트는 `Win64`에 그대로 남음. DX11과 DX12가 같은 `dxgi.dll` 하나를 쓰는 환경에 적합.
- 메뉴 `4`로 바꾸면 `wwmi_dx12_toggle.cfg`에 저장되어 유지됨.
- **백업에 항목이 남아 있는 Off 상태에서는 바꿀 수 없음.** 먼저 `2`(On)로 복원한 뒤 바꿔야 함.

## 동작 방식

1. 저장된 경로를 읽고, 없거나 틀리면 경로 선택 화면을 띄움.
2. `Win64`에 `Client-Win64-Shipping.exe`가 있는지 확인.
3. 게임이 실행 중이면 중단.
4. **Off**: 백업 폴더에 이미 항목이 있으면 덮어쓰지 않고 중단. 없으면 대상 항목을 백업 폴더로 이동.
5. **On**: `Win64`에 같은 이름이 이미 있으면 덮어쓰지 않고 중단. 없으면 백업의 항목을 `Win64`로 이동.
6. 같은 드라이브면 바로 이동하고, 다른 드라이브면 폴더를 복사한 뒤 파일 수와 용량이 같은지 확인하고 나서 원본을 지움. 확인이 맞지 않으면 원본을 지우지 않음.
7. 마지막에 현재 상태를 다시 표시.

### 상태 표시

| 상태 | 의미 |
| --- | --- |
| 설치됨 (On) | `Win64`에만 있음 |
| 백업됨 (Off) | 백업에만 있음 |
| 양쪽 모두 없음 | 어디에도 대상 항목이 없음 |
| 양쪽에 모두 있음 | 직접 정리가 필요함. 도구가 자동으로 합치지 않음 |

## 구성 파일

| 파일 | 역할 |
| --- | --- |
| `wwmi_dx12_toggle.bat` | 실행용. PowerShell 스크립트를 호출하고 받은 인자를 그대로 전달 |
| `wwmi_dx12_toggle.ps1` | 본체 |
| `wwmi_dx12_toggle.cfg` | 명조 경로와 ReShade 포함 여부 저장. 실행 시 자동 생성되며 저장소에 포함하지 않음 |
| `backup\` | 옮겨 둔 파일이 쌓이는 폴더. 실행 시 자동 생성되며 저장소에 포함하지 않음 |

`cfg` 파일을 지우면 경로를 다시 묻고, ReShade 포함 여부는 기본값(포함)으로 돌아감.

## 사용 시 주의할 점

- **백업 폴더는 스크립트가 있는 폴더 옆에 하나만 만들어짐.** 클라이언트가 여러 개면 도구 폴더를 클라이언트별로 따로 복사해서 써야 백업이 섞이지 않음.
- **Off 상태에서 WWMI-DX12를 업데이트하지 말 것.** 먼저 On으로 복원한 뒤 업데이트해야 `wwmi_dx12.ini` 같은 설정 파일이 꼬이지 않음. (Off 상태에서 새 버전을 풀면 On 때 이름 충돌로 복원이 중단됨.)
- 이 도구는 `Win64` 안의 파일만 옮김. 런처(`.bat`/`.ps1`)가 수정하는 `Engine.ini` 같은 게임 설정 파일은 되돌리지 않음.
- 스크립트를 다른 위치로 옮기면 `backup\` 위치도 달라지므로, 백업이 있는 상태(Off)에서는 `backup` 폴더도 함께 옮길 것.

## 면책 조항

- 이 도구는 개인이 만든 비공식 도구이며, 쿠로게임즈(Kuro Games) 및 명조(Wuthering Waves), WWMI-DX12 제작자와 관련이 없음. 게임 이름과 상표는 각 소유자의 것임.
- 명조 `Win64` 폴더 안의 WWMI-DX12 관련 파일(옵션에 따라 ReShade 파일 포함)을 백업 폴더로 이동하거나 되돌림. 게임 실행 파일과 그 밖의 게임 파일은 수정하지 않음.
- 이 도구는 WWMI-DX12 및 ReShade 사용 자체의 안전성을 보장하지 않음. 해당 도구와 게임 약관·정책은 사용자가 직접 확인해야 함.
- 이 도구의 사용으로 생기는 데이터 손실, 게임 문제, 계정 관련 불이익 등 어떠한 결과에 대해서도 작성자는 책임지지 않음. 사용에 따른 책임은 사용자에게 있음.

## 라이선스

[MIT License](../LICENSE)
