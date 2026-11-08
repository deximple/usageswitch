# UsageSwitch

남은 AI 사용량을 확인하고, 원할 때 Claude/Codex 계정을 전환하는 앱입니다.

설치된 AI 도구와 등록 계정의 남은 한도를 메뉴 막대에서 확인합니다. Claude Desktop 로그인을 전환하거나 Codex 계정을 서로 다른 창에서 여는 기능도 제공합니다.

[English](README.md) · 다운로드: [최신 릴리스](https://github.com/deximple/usageswitch/releases/latest) · [개인정보](PRIVACY.md) · [변경 기록](CHANGELOG.md)

<p><img src="docs/screenshots/usage-quiet-list.png" width="420" alt="UsageSwitch 네이티브 사용량 목록, 데모 데이터"></p>
<sub>스크린샷: 개발 미리보기, 합성 데모 데이터 — 실제 계정이나 할당량은 나오지 않습니다.</sub>

앱은 English, 한국어, 简体中文, 日本語, Español을 지원합니다 (시스템 언어를 따릅니다;
⚙︎ › 언어에서 바꿀 수 있습니다). 버전 2.1.0.

## 요구 사항

- macOS 15 이상 — Apple silicon과 Intel 모두.
- 공개 릴리스는 Developer ID로 서명하고 Apple 공증을 받습니다.
  개발 미리보기는 ad-hoc 서명만 있고 공증되지 않습니다.
- 계정 전환에는 Claude Desktop 또는 Codex 데스크톱 앱이 필요합니다. 사용량만 보는
  환경은 지원되는 로컬 CLI만으로 충분합니다.

## 설치

1. [최신 릴리스](https://github.com/deximple/usageswitch/releases/latest)에서 `UsageSwitch-<버전>.dmg`(또는 `.zip`)를 받습니다.
2. 열어서 **UsageSwitch**를 Applications으로 드래그합니다.
3. 실행하면 메뉴 막대에 상주합니다. Finder에서 열면 창도 함께 나타납니다.

## 작동 방식

사용량 목록은 **환경 우선**입니다 — 설치되거나 등록된 제공자만 보여주고, 고정된
7개 카탈로그가 아닙니다. 탐지는 CLI 실행 파일과 `.app` 디렉터리의 파일 시스템
사실만 보고 후보를 실행하지 않으며, 사용자가 지정한 PATH 순서대로 찾습니다. Claude·Codex·
Cursor가 있으면 정확히 셋만 보이고, Claude만 있는 환경은 Claude와 저장된 계정만
보입니다. 없는 제공자는 인증 읽기나 수집 작업을 만들지 않습니다.

360pt 메뉴에는 각 한도의 **남은 비율**과 초기화까지 남은 시간을 `25% · 2d 3h`처럼
표시합니다. 최신 상태를 확인할 수 있는 한도를 계정당 최대 3개 보여 주고, 나머지는
상세 보기에서 확인합니다. 선택적 **가이드**는 비교 가능한 구독 한도를 바탕으로 다음
계정 후보를 최대 하나 제시합니다. 계정을 자동으로 전환하거나 앱을 열지는 않습니다.

**상세 보기**에서는 전체 한도, 초기화 시각, 수집 경로와 도구 버전을 확인하고 등록된
Claude 계정에 사용자가 선택한 CLI 프로필을 명시적으로 연결하거나 해제할 수 있습니다.
동의한 뒤 공식 CLI의 인증 상태와 `/usage`만 읽습니다. Claude/Codex 계정의 **표시 이름**도
고칠 수 있습니다. 이름 변경은 목록과 가이드에
바로 반영되며 로그인, 이메일, 플랜을 바꾸거나 사용량을 다시 수집하지 않습니다.
명령줄 JSON에는 다음 갱신 전까지 마지막 수집 시점의 이름이 남습니다. 상세 보기에서
제공자 로그인이나 계정 전환을 실행하지는 않습니다.

Claude CLI 할당량은 기본적으로 저장된 Claude App 계정에 연결되지 않습니다. 저장된
계정별 상세 화면에서 사용자가 직접 로그인한 Claude CLI 프로필을 선택하고 **활성화**를
확인해 별도로 연결할 수 있습니다. UsageSwitch는 해당 프로필로 공식 CLI의
`claude auth status --json`과 `/usage`를 실행하며, 읽기 전후에 같은 계정과 조직이
확인된 경우에만 할당량을 표시합니다. CLI는 자체 저장된 로그인을 읽으며(macOS 키체인을
사용할 수도 있음) 자체 토큰을 갱신하거나 설정 파일을 업데이트할 수 있습니다.
UsageSwitch는 `.claude.json`의 계정 및 조직 ID만 읽습니다. 작업이나 모델 요청을 실행하거나
로그인·로그아웃·계정 전환을 하지 않습니다. 연결 해제 시 프로필을 변경하거나 삭제하지 않고
바인딩과 표시된 사용량만 제거합니다. API 프로필은 구독 잔액이 아니라 `API`로 표시됩니다.

## 제공자

| 제공자 | 읽기 경로 | 가용성 |
|---|---|---|
| Claude Code | CLI `/usage` | 현재 CLI 로그인; 관리 설정이 있으면 거부 |
| 저장된 Claude 계정 | 선택적 공식 CLI 프로필 (`auth status --json` 후 `/usage`) | 계정별 명시적 연결; 매 읽기 전후 프로필 ID와 인증 상태 확인 |
| Codex | `app-server` → `account/rateLimits/read` | 등록된 ChatGPT 홈; API 키 프로필은 구독 할당량 없음 |
| Cursor | 현재 기간 사용량 엔드포인트(총계와 유효한 `Auto`/`API` 윈도우) | 직접 켜야 사용; 자체 키체인 항목 또는 제한된 인증 파일 |
| Grok | CLI 사용량 엔드포인트 | 직접 켜야 사용; **실험** |
| Gemini | Code Assist 프로젝트/할당량 | 직접 켜야 사용; Keychain 후 기존 인증 파일(암호화 파일 저장은 미지원); 모델/입력/출력 한도 분리 |
| Antigravity | 숨겨진 `agy` `/usage` 화면; 읽기 전용 Code Assist 쿼터 API 폴백/보강 | 직접 켜야 사용; agy 키체인 로그인으로 임시 메모리 토큰을 쓸 수 있음 |
| Devin | CLI 호환 사용자 상태 | 직접 켜야 사용; 지원되는 CLI 버전 필요 |
| OpenCode Go | Go 사용량 엔드포인트 | 직접 켜야 사용; 전체 OpenCode 합계가 아닌 Go 플랜만 |

선택적 제공자 여섯 개는 모두 **기본 꺼짐**입니다. 켤 때 UsageSwitch가 그 제공자의
로컬 로그인을 읽고 고정 허용 목록으로 읽기 전용 HTTPS 요청을 보낸다고 알립니다 —
리다이렉트 거부, 응답 크기 제한. Gemini는 API 요청을 최대 두 번, Antigravity는 토큰 교환과
쿼터 API 요청을 최대 두 번 보낼 수 있습니다.
Gemini의 강제 암호화 파일 저장 모드는 지원하지 않으며 로그인되지 않은 것으로 처리합니다.
Antigravity는 사용자 홈 폴더에서 숨겨진 터미널로 `agy`를 실행해 `/usage`를 읽으며,
최대 9분에 한 번만 실행합니다. `agy`는 사용자가 설정한 MCP 서버를 포함해 평소 설정으로
시작합니다. UsageSwitch는 폴더 신뢰 프롬프트를 포함한 `agy`의 어떤 프롬프트에도 응답하지
않으며, 프롬프트가 나타나면 입력하지 않고 읽기 전용 쿼터 API로 대체합니다. 이 API는
필요할 때 `gemini` / `antigravity-acp` 키체인 항목으로 임시 액세스 토큰을 메모리에만
가져올 수 있습니다. macOS가 키체인 접근을 허용할지 물을 수 있습니다. 토큰을 저장하거나
`agy` 설정을 쓰지 않습니다.
선택적 제공자 토큰은 수집기가 저장하거나 기록하지 않습니다. 새 연결기는 **실험**입니다 — 비공개 엔드포인트는
바뀔 수 있고 실제 계정 호환성은 아직 검증되지 않았습니다. UsageSwitch는 로그인·
로그아웃·계정 전환·모델 작업을 하지 않습니다. 명시적으로 연결한 Claude 프로필에서는
공식 CLI가 자체 토큰을 갱신하거나 설정 파일을 업데이트할 수 있습니다. 사용량 수집은
모델 요청을 하지 않습니다. 분석, 원격 측정, 백그라운드 자동 업데이트가 없습니다.

## 계정 동작

- **Claude 탭** — 각 계정의 Claude Desktop 로그인을 한 번 저장한 뒤 클릭 한 번으로
  전환합니다. 전환은 Claude를 정상 종료하고(강제 종료 없음), Code 세션이 돌고 있으면
  먼저 묻고, 로컬 로그인을 바꾼 뒤 Claude 로그로 검증하고, 실패하면 롤백합니다.
  서버에서 로그아웃하지 않습니다.
- **Codex 탭** — 계정당 Codex 홈 하나, 각각 자기 창에서 엽니다. 로그인은 항상
  Codex 자체 CLI를 통해 이루어지고 `auth.json`을 홈 사이에서 복사하거나 바꾸지
  않습니다(Codex 갱신 토큰은 일회용). 추가된 홈을 지우면 로그아웃되므로 제거는
  신중한 동작입니다 — 표준 `~/.codex`는 지울 수 없습니다.
- 둘 다 **사용자가 시작한** 동작입니다 — UsageSwitch는 요청할 때만 앱을 닫거나 열고,
  할당량 때문에 자동으로 그러지 않습니다.

## 명령줄 (읽기 전용 예시)

```bash
APP=/Applications/UsageSwitch.app/Contents/MacOS/UsageSwitch
"$APP" --cli status        # Claude 계정 + 현재 계정 + Code 세션
"$APP" --cli codex status  # Codex 홈
"$APP" --cli usage         # 마지막 읽기 JSON — 저장된 마스킹 스냅샷만 읽음;
                           # 실시간 수집 없음, 이름 편집은 다음 갱신까지 지연
```

명령 없이 `"$APP" --cli`를 실행하면 전체 목록이 나옵니다.

## 개인정보와 안전

사용량은 표시 전용입니다. 한도 때문에 계정을 전환하거나 앱을 열거나 로그인하지 않습니다. 추가 제공자 여섯 종은 사용자가 연결을 켠 뒤에만 로그인 정보를 읽습니다. 해당 수집기는 토큰을 저장하거나 로그에 남기지 않습니다. 계정 전환에 필요한 Claude 로그인 사본은 암호화된 쿠키 DB 상태로 이 Mac에 저장합니다. 수집 오류의 원문이나 인증 값은 화면에 표시하지 않습니다. 자세한 수집 경로와 저장 범위는 [PRIVACY.md](PRIVACY.md)를 확인하세요.

API 탭의 지출은 API 키 계정으로 표시된 계정의 로컬 로그만 사용한 추정치이며, 실제 잔액이 아닙니다. 예산은 로컬에 저장됩니다. 선택적으로 입력한 API 키는 macOS 키체인에 보관되며 어디에도 전송되지 않습니다. 확인된 읽기 전용 잔액 API가 없기 때문입니다.

## 빌드와 기여

macOS 15+에서 Xcode 16+ (Swift 6) 필요.

```bash
swift build
./scripts/test.sh              # 테스트 + 커버리지
./scripts/bundle.sh            # 유니버설 번들; Developer ID가 있으면 사용하고
                                # 로컬 빌드는 ad-hoc으로 폴백
python3 scripts/check-l10n.py  # 로컬라이제이션 키 점검
```

`scripts/notarize.sh`는 기존 `NOTARY_PROFILE` 키체인 프로필로 Apple 공증을 제출합니다 —
릴리스는 ad-hoc 폴백을 쓸 수 없습니다.

## 제한

- 전환은 Claude Desktop 내부 파일에 의존합니다 — Claude 업데이트가 바꾸면
  UsageSwitch 업데이트 전까지 안전하게 실패·롤백합니다.
- 저장된 Claude 로그인은 만료되거나 취소되어 다시 로그인해야 할 수 있습니다.
- 키체인에 로그인을 두는 Codex 홈(`cli_auth_credentials_store = "keyring"`)은
  로그아웃으로 보일 수 있습니다.
- 선택적 제공자 연결기는 실험입니다 — 실제 계정 호환성은 검증되지 않았습니다.
- 비용·잔액·모델별 지출은 없습니다 — 할당량은 각 제공자가 보고한 값 그대로입니다.

## 제거

1. 선택 사항: 추가한 Codex 계정도 로그아웃하려면 앱을 종료하기 전에 Codex 탭에서 제거합니다.
2. ⚙︎ › **로그인할 때 열기**를 끄고, UsageSwitch를 종료한 뒤 휴지통으로 옮깁니다.
3. 데이터 폴더(`~/Library/Application Support/com.jaysong.usageswitch/`)를 지우면
   저장된 로그인·설정·UsageSwitch가 추가한 Codex 홈이 함께 사라집니다 — 필요한
   데이터는 먼저 보관하세요.

## 감사

독립 오픈소스 프로젝트입니다 — Anthropic, OpenAI, Cursor, xAI, Google, Cognition,
Sourcegraph와 무관하며 제품명은 각 소유자의 것입니다. 관련 커뮤니티 스위처:
[claudepot-app](https://github.com/xiaolai/claudepot-app),
[claude-desktop-accounts](https://github.com/5eanxlee/claude-desktop-accounts),
[Swivel](https://github.com/jspanji/Swivel), [claude-graft](https://github.com/aaditya-v-more/claude-graft).

## 라이선스

MIT — [LICENSE](LICENSE) 참조.
