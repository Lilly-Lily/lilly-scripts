# 명조 셰이더 캐시 정리 도구

Wuthering Waves Shader Cache Cleaner

명조(Wuthering Waves) 다중 클라이언트용 셰이더 캐시 정리 도구.

GPU 드라이버·DirectX 셰이더 캐시와 명조 클라이언트별 PSO 캐시(선택 시 Steam 셰이더 캐시까지)를 비워서, 게임이 현재 드라이버 환경에 맞게 셰이더를 새로 만들도록 함. 드라이버 업데이트나 게임 패치 뒤 생기는 스터터링을 정리하는 용도.

> [!WARNING]
> 비공식 도구임. 관리자 권한으로 캐시 폴더의 파일을 삭제하므로, 아래 [면책 조항](#면책-조항)을 먼저 읽을 것.

## 주요 기능

- 명조 클라이언트 여러 개(런처판·Steam판 혼용 가능)의 `PSO`, `PSOReport` 캐시 일괄 정리
- NVIDIA·AMD·Intel 드라이버 셰이더 캐시와 Windows DirectX 셰이더 캐시 정리
- Steam 셰이더 캐시 정리(선택, 기본값 꺼짐)와 Steam 라이브러리 자동 감지
- 창(UI)에서 경로를 추가·변경·삭제하고 설정을 자동 저장
- 진행 상황을 창과 로그 파일에 기록

## 요구 사항

- Windows 10 / 11
- Windows PowerShell 5.1 (Windows에 기본 포함)
- 관리자 권한

## 사용법

1. 저장소를 내려받아 `WWCacheCleaner.bat`과 `WWCacheCleaner.ps1`을 같은 폴더에 둠.
2. 인터넷에서 받은 파일이라 실행이 막히면, `.ps1` 파일 속성에서 **차단 해제**를 체크함.
3. 명조와 런처를 모두 종료함.
4. `WWCacheCleaner.bat`을 더블클릭하고 UAC 창에서 [예]를 누름.
5. 명조 설치 루트 폴더를 등록하고(예: `D:\Wuthering Waves`) [캐시 정리 실행]을 누름.

## 구성 파일

| 파일 | 역할 |
| --- | --- |
| `WWCacheCleaner.bat` | 실행 정책을 우회(`-ExecutionPolicy Bypass`)하고, 콘솔 창을 숨긴 채 `.ps1`을 실행하는 런처 |
| `WWCacheCleaner.ps1` | 창(UI), 경로 판별, 캐시 삭제, 로그 기록을 모두 담당하는 본체 |
| `settings.json` | 명조 경로, Steam 정리 여부, Steam 라이브러리 목록. 처음 실행할 때 생기고, 설정을 바꿀 때마다 자동 저장 |
| `ShaderCacheCleanup.log` | 마지막 실행 결과. 실행할 때마다 새로 씀 |

로직은 모두 `.ps1` 안에 있어서 메모장으로 열어 바로 확인하고 고칠 수 있음. `settings.json`과 로그 파일은 개인 환경 파일이라 저장소에 포함하지 않음.

## 실행 흐름

1. **관리자 권한 확인**: 관리자가 아니면 UAC를 요청해 자기 자신을 관리자 권한으로 다시 실행함. `ProgramData`나 `Program Files` 아래 캐시를 지우려면 필요함.
2. **준비**: 고해상도(DPI) 대응을 켜고, 탐색기 방식 폴더 선택 창(Windows의 `IFileOpenDialog`)을 C# 코드로 불러옴. 실패하면 기존 트리형 창으로 대체함.
3. **설정 불러오기**: `settings.json`을 읽어 목록을 채우고, 경로마다 감지 상태를 표시함. 파일이 없으면 기본값으로 시작함.
4. **실행 전 확인**: [캐시 정리 실행]을 누르면 명조 프로세스(`Client-Win64-Shipping`)가 떠 있는지 보고, 실행 중이면 계속할지 물어봄.
5. **정리**: GPU·DirectX 캐시 → Steam 캐시(켜진 경우) → 명조 PSO 캐시 순서로 지우고, 한 줄씩 창과 로그 파일에 기록함.
6. **요약**: 마지막에 OK·WARN·SKIP 개수를 출력하고 감지 상태를 새로 고침.

## 정리 대상

모두 '다시 만들 수 있는 캐시'만 지움. 폴더 자체는 남기고 안의 내용만 비우는 방식임.

| 구분 | 대상 폴더 | 범위 |
| --- | --- | --- |
| Windows | `%LOCALAPPDATA%\D3DSCache` (디스크 정리의 'DirectX 셰이더 캐시') | 전체 |
| NVIDIA | `%LOCALAPPDATA%\NVIDIA\` 아래 `DXCache`, `GLCache`, `VkCache` / `%APPDATA%\NVIDIA\ComputeCache` / `LocalLow\NVIDIA\PerDriverVersion\` 아래 `DXCache`, `GLCache` | 전체 |
| NVIDIA | `%ProgramData%\NVIDIA Corporation\NV_Cache` | 맨 위 파일만. NGX 등 하위 폴더는 보존 |
| AMD | `%LOCALAPPDATA%\AMD\` 아래 `DxCache`, `DxcCache`, `GLCache`, `VkCache` / `LocalLow\AMD\DxCache` | 전체 |
| Intel | `%LOCALAPPDATA%\Intel\ShaderCache` / `LocalLow\Intel\ShaderCache` | 전체 |
| Steam (선택) | 등록한 라이브러리마다 `steamapps\shadercache` | 전체 |
| 명조 | 등록한 클라이언트마다 `Client\Saved\PSO`, `Client\Saved\PSOReport` | 전체 |

명조 경로는 설치 루트만 등록하면 됨. 프로그램이 `루트\Wuthering Waves Game\Client\Saved`(런처판)와 `루트\Client\Saved`(Steam판)를 차례로 확인해서 있는 쪽을 씀. Steam 라이브러리는 [자동 감지]로 레지스트리의 Steam 설치 위치와 `libraryfolders.vdf`를 읽어 찾을 수 있음.

## 삭제와 결과 판정

폴더 안의 항목을 하나씩 강제 삭제하고, 실패한 항목은 건너뛴 뒤 남은 파일 수를 세서 판정함. 다른 프로그램이 열어 둔 파일은 Windows가 삭제를 막기 때문에, 일부가 남는 것은 정상임.

| 결과 | 의미 | 대응 |
| --- | --- | --- |
| `[OK]` | 내용을 모두 지움 | 없음 |
| `[WARN]` | 사용 중인 파일 N개를 건너뜀 | 보통 그대로 두면 됨. 완전히 비우려면 재부팅 직후 실행 |
| `[SKIP]` | 폴더가 없거나 기능이 꺼짐 | GPU 제조사가 다르면 당연히 뜸. 명조 항목이 SKIP이면 경로를 확인 |

명조 PSO 폴더는 지워도 게임을 실행하면 다시 생김. GPU 캐시도 게임을 하면서 새로 쌓임.

## 사용 시점과 주의할 점

그래픽 드라이버를 업데이트했거나, Engine.ini를 바꿨거나, 게임 패치 뒤 스터터링이 생겼을 때 실행하면 됨. 매번 돌릴 필요는 없음.

- 정리 직후 첫 실행에서는 셰이더 컴파일이 다시 일어나서, 초반 몇 분은 이펙트가 처음 나올 때 끊김이 있을 수 있음.
- Steam 정리를 켜면 모든 Steam 게임이 셰이더를 다시 컴파일함.
- 프로그램이 다루지 않는 것: Engine.ini 수정, 드라이버 제어판의 셰이더 캐시 크기 설정, 명조 외 게임의 자체 캐시 폴더.
- 정리 대상 목록을 바꾸려면 `.ps1`의 `$GpuCaches` 부분을 고치면 됨.

## 면책 조항

- 이 도구는 개인이 만든 비공식 도구이며, Kuro Games 및 명조(Wuthering Waves)와 관련이 없음. 게임 이름과 상표는 각 소유자의 것임.
- 게임 실행 파일이나 데이터 파일은 수정하지 않고, 위 표에 적힌 캐시 폴더의 내용만 삭제함.
- 관리자 권한으로 파일을 삭제하는 도구이므로, 실행 전에 `.ps1`의 내용을 직접 확인할 것을 권장함.
- 이 도구의 사용으로 생기는 데이터 손실, 게임 문제, 계정 관련 불이익 등 어떠한 결과에 대해서도 작성자는 책임지지 않음. 사용에 따른 책임은 사용자에게 있음.

## 라이선스

[MIT License](LICENSE)
