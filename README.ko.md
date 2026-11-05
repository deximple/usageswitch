# UsageSwitch

로컬 AI 환경의 사용량을 확인하고 Claude/Codex 계정을 관리하는 macOS 메뉴바 앱입니다.

- **사용량 탭** — 감지된 도구와 등록 계정의 남은 한도·리셋을 간결하게 보여줍니다. 상세 보기에서 전체 한도를 읽고 저장 계정의 표시 이름을 바꿀 수 있으며, 가이드는 다음 계정 후보를 최대 하나 제시합니다.
- **Claude 탭**: 계정마다 Claude Desktop 로그인을 한 번 저장해 두면, 클릭 한 번으로 Claude Desktop(Code 탭 포함)을 그 계정으로 전환합니다. 로그아웃했다가 다시 로그인할 필요가 없습니다.
- **Codex 탭**: Codex 계정마다 자기 Codex 홈을 두고, 각각 별도 창으로 나란히 엽니다.

[English](README.md) · 내려받기: [최신 릴리스](https://github.com/deximple/usageswitch/releases/latest) · [개인정보](PRIVACY.md) · [변경 내역](CHANGELOG.md)

<p>
  <img src="docs/screenshots/usage-tab.png" width="49%" alt="사용량 탭: 가이드 보기">
  <img src="docs/screenshots/usage-all.png" width="49%" alt="사용량 탭: 계정별 창 진행 막대">
</p>
<p>
  <img src="docs/screenshots/claude-tab.png" width="49%" alt="Claude 탭: 저장된 계정마다 전환 버튼">
  <img src="docs/screenshots/codex-tab.png" width="49%" alt="Codex 탭: 계정마다 Codex 홈">
</p>

<sub>스크린샷은 데모 데이터입니다.</sub>

화면 언어는 한국어 · 简体中文 · 日本語 · English · Español 입니다. 기본값은 시스템 언어이고 ⚙︎ › 언어에서 바꿉니다.

## 사용량

고정된 7종 목록이 아니라 실제 로컬 환경을 먼저 보여줍니다. Claude/Codex/Cursor가 있으면 그 세 종류만, Claude만 쓰면 Claude와 저장 계정만 나타납니다. 설치·저장된 로그인·확인된 한도는 구분하며, Claude CLI에서 읽은 한도를 저장된 App 계정에 복사하지 않습니다.

| 제공자 | 조회 경로 | 범위 |
|---|---|---|
| Claude Code | CLI `/usage`, Claude Code 자체 자격증명 | 기본 CLI 로그인, 관리 설정이 있으면 거부 |
| Codex | `app-server` → `account/rateLimits/read` | 등록된 ChatGPT 홈, API 프로필의 구독 한도는 조회하지 않음 |
| Cursor | Dashboard 사용량·플랜 조회 | 명시적 동의, 키체인 또는 크기를 제한한 인증 파일 |
| Grok | CLI 사용량 엔드포인트 | 명시적 동의, 실험적 연동 |
| Gemini | Code Assist 프로젝트·할당량 조회 | 명시적 동의, 모델·토큰별 한도를 분리 |
| Devin | CLI 호환 사용자 상태 조회 | 명시적 동의, 지원하는 CLI 버전 필요 |
| OpenCode Go | Go 사용량 조회 | 명시적 동의, OpenCode의 모든 제공자를 합산하지 않음 |

이 개발 브랜치의 추가 제공자 연동은 실험적입니다. 비공개 엔드포인트는 바뀔 수 있고 실제 계정 호환성은 아직 검증하지 않았습니다. 표는 구현한 조회 경로이며, 모든 플랜·인증 방식에서 한도가 나온다는 뜻은 아닙니다.

**설정 > 사용량 연결**에서 제공자의 로컬 로그인 정보를 읽고 HTTPS 요청을 보내기 전에 동의를 받습니다. 선택적 연결 5종은 기본으로 꺼져 있습니다. Cursor와 Gemini는 갱신마다 요청을 최대 두 번 보낼 수 있습니다. 토큰은 저장·기록하지 않으며, 리디렉션을 차단하고 응답 크기를 제한합니다. 연결을 끄거나 환경이 없으면 인증 읽기와 수집 작업을 시작하지 않습니다. 출처와 전송 대상은 [개인정보 문서](PRIVACY.md)를 참고하세요.

사용량은 보여주기만 합니다. 한도 때문에 계정을 바꾸거나 앱을 실행·로그아웃하지 않습니다. 그 위에 이런 기능이 더해집니다:

- **가이드** — 같은 종류·길이의 공통 한도를 보고한 계정끼리만 비교해 다음 계정 후보를 최대 하나만 제시합니다. 비율은 각 한도의 남은 비중 비교이며 토큰 수가 아닙니다. 저절로 앱을 열거나 전환하지 않습니다.
- **페이스** — 리셋 전에 소진될 만큼 빠르게 줄어드는 창이 있으면 그 행에 표시합니다.
- **상세 보기** — 전체 한도 이름·리셋·조회 경로를 보여줍니다. Claude/Codex의 표시 이름은 기존 계정 레지스트리에 저장하고, 사용량을 다시 수집하지 않고 목록·가이드에 반영합니다. 빈 이름은 저장할 수 없으며 기본 이름은 별도 버튼으로 복원합니다. CLI 스냅샷은 다음 정상 갱신 전까지 마지막 수집값을 유지합니다.
- **알림** — 창이 경고 기준을 넘으면 macOS 알림을 띄웁니다(⚙︎ › 사용량 알림, 옆의 '사용률 경고 기준' — 기본 80% 사용 시).
- **`--cli usage`** — 마지막으로 읽은 사용량을 JSON 으로 출력합니다. 스크립트·에이전트용입니다. 스냅샷 파일만 읽는데, 레이블은 이메일 표시 설정과 무관하게 항상 마스킹되어 있습니다. 벤더 도구·키체인·네트워크에는 닿지 않습니다.

외관은 **시스템 설정 따르기 / 라이트 / 다크** 중 고르며 명시한 선택은 저장합니다. 사용량 수집은 로그인·로그아웃·토큰 갱신·계정 전환·모델 작업을 실행하지 않습니다. API 프로필은 `API`로 표시하며 구독 잔액으로 취급하지 않습니다.

## 설치

1. [최신 릴리스](https://github.com/deximple/usageswitch/releases/latest)에서 `UsageSwitch-<버전>.dmg` 를 내려받습니다.
2. 열어서 **UsageSwitch** 를 **응용 프로그램(Applications)** 으로 끌어 놓습니다.
3. UsageSwitch 를 엽니다. 메뉴바에 상주하며, Finder 에서 열면 창도 함께 뜹니다.

공개 릴리스는 Developer ID로 서명하고 Apple 공증(notarization)을 받습니다. 이 브랜치의 개발 미리보기는 ad-hoc 서명이며 공증하지 않았습니다.

**요구 사항:**
- macOS 15 이상, Apple 실리콘 또는 Intel.
- 계정 전환에는 `/Applications` 또는 `~/Applications`의 [Claude Desktop](https://claude.ai/download)이나 Codex 데스크톱 앱이 필요합니다. 사용량만 확인하는 환경은 데스크톱 앱 없이 지원 CLI를 사용할 수 있습니다.

## Claude 탭

### 계정 추가(계정마다 한 번)

1. Claude Desktop 이 원하는 계정으로 로그인되어 있으면 **현재 로그인 저장**을 누릅니다.
2. 다른 계정을 추가하려면 **새 계정 로그인**을 누릅니다. 현재 로그인을 저장한 뒤 Claude 가 로그인 화면으로 다시 열립니다.
   - 이 Mac 의 로그인만 지웁니다. 서버에서 로그아웃하는 것이 아닙니다.
3. Claude 에서 다른 계정으로 로그인한 뒤 **현재 로그인 저장**을 누릅니다.

계정은 이메일 이름으로 목록에 보입니다. 연필 버튼이나 우클릭 › **이름 바꾸기…** 로 "회사" 같은 이름을 붙일 수 있습니다.

이메일은 클릭하기 전까지 가려집니다. 항상 보려면 ⚙︎ › **이메일 항상 보이기**를 켭니다.

### 전환

창이나 메뉴바에서 계정 옆의 **전환**을 누릅니다. Claude 가 종료되었다가 그 계정으로 다시 열리고, 진행 단계가 그대로 보입니다.

- 실행 중인 Code 세션은 Claude 가 종료될 때 멈추므로, 전환 전에 먼저 묻습니다. 세션 기록은 계정별로 남아 있어 그 계정으로 돌아오면 다시 보입니다.
- Claude 가 "Claude is still working" 대화상자를 띄우면 기다립니다. 그래도 종료되지 않으면 아무것도 바꾸지 않고 멈춥니다.

계정을 우클릭하면 다음 메뉴가 있습니다.

- **이름 바꾸기…**
- **재로그인…**: 저장된 로그인을 새로 고칩니다. 예를 들어 만료됐을 때 씁니다.
- **저장된 로그인 삭제**: 이 Mac 의 저장본만 지우며, 계정 자체나 다른 기기에는 영향이 없습니다. 사용 중인 계정에는 없습니다.

## Codex 탭

Codex 는 로그인을 Codex 홈(기본 `~/.codex`)에 저장합니다. UsageSwitch 는 계정마다 홈을 하나씩 두고 각각 별도 Codex 창으로 열기 때문에, 여러 계정을 동시에 열 수 있습니다.

여는 방식은 Codex 가 자기 두 번째 창을 여는 방식과 같습니다. `CODEX_HOME` 과 별도 앱 데이터 폴더를 씁니다.

- **Codex 계정 추가**: 새 Codex 홈을 만들고 Codex 자신의 `codex login` 을 실행합니다. 브라우저에서 로그인하면 그 계정으로 Codex 가 열립니다.
- **열기 / 보기**: 그 계정의 Codex 창을 엽니다. 이미 열려 있으면 앞으로 가져옵니다.
- **로그인**: 로그아웃된 계정을 다시 인증합니다. 다른 계정은 우클릭 › **재인증…** 으로 같은 일을 합니다.
- **제거…**
  - UsageSwitch 에서 추가한 계정: 그 계정의 Codex 창을 닫고 `codex logout` 으로 로그아웃한 뒤, 홈 폴더를 휴지통으로 옮깁니다.
  - **이 Mac 에서 찾은 Codex 홈**에서 추가한 홈: 목록에서만 뺍니다(**목록에서 제거…**).
  - 기본 `~/.codex` 는 제거할 수 없습니다.
- **이 Mac 에서 찾은 Codex 홈**: `~/.codex-work` 같은 기존 홈을 제안만 하고 쓰지는 않습니다.
  - 실제 계정인 것만 **목록에 추가**하고, 백업이나 복사본은 건너뜁니다.
  - 같은 로그인을 가진 홈 두 개는 서로를 로그아웃시킵니다.
- 우클릭 메뉴에는 **이름 바꾸기…**, **터미널 명령 복사**(`CODEX_HOME=… codex`), **Finder에서 보기**도 있습니다.

로그인 정보는 홈 사이에서 복사하거나 바꿔 끼우지 않습니다. Codex 의 갱신 토큰은 한 번만 쓸 수 있어서, `auth.json` 을 바꿔 끼우면 로그인이 풀릴 수 있기 때문입니다.

로그인과 로그아웃은 Codex 자신의 CLI 가 합니다. 예외는 **제거…** 하나입니다. `codex logout` 이 끝나지 않으면 UsageSwitch 가 그 홈의 `auth.json` 을 직접 지워, 살아 있는 로그인이 휴지통으로 가지 않게 합니다.

## 설정(⚙︎)

| 설정 | 하는 일 |
|---|---|
| 언어 | 시스템 언어, 또는 앱의 5개 언어 중 하나 |
| 외관 | 기본은 시스템 설정을 따르고, 라이트·다크로 고정할 수 있습니다(선택은 저장됩니다) |
| 로그인 시 자동 실행 | 로그인 때 실행되면 창 없이 메뉴바에만 뜹니다 |
| 메뉴바에 계정 이름 표시 | 끄면 아이콘만 보입니다 |
| 이메일 항상 보이기 | 클릭하지 않아도 이메일을 보여 줍니다 |
| 숨긴 Codex 홈 다시 보기 | 찾은 홈을 숨긴 적이 있을 때만 보입니다 |
| 데이터 폴더 보기 | 아래 "개인정보와 안전"에 나오는 폴더를 엽니다 |
| 업데이트 확인… | 브라우저에서 릴리스 페이지를 엽니다 |
| UsageSwitch 정보 | 버전 |

## 명령줄

앱 실행 파일에 JSON 을 출력하는 명령줄 인터페이스가 들어 있습니다.

```bash
APP=/Applications/UsageSwitch.app/Contents/MacOS/UsageSwitch
"$APP" --cli status                  # 계정 목록, 사용 중인 계정, Code 세션
"$APP" --cli switch <계정> --yes      # <계정>: status 의 id, 이름 또는 이메일
"$APP" --cli capture --yes           # 지금 Claude 로그인 저장
"$APP" --cli enroll --yes            # 새 계정 로그인 준비(로그인 화면으로 Claude 재실행)
"$APP" --cli rename <계정> "회사"      # --reset: 기본 이름으로
"$APP" --cli remove <계정>            # 저장된 로그인 삭제(사용 중인 계정은 불가)
"$APP" --cli codex status            # Codex 계정 목록
"$APP" --cli usage                   # 마지막으로 읽은 사용량
"$APP" --cli codex open <계정>
"$APP" --cli codex add               # 브라우저 로그인, Ctrl-C 로 취소
"$APP" --cli --lang ko status        # 이번 실행만 다른 언어로
```

명령 없이 `"$APP" --cli` 만 실행하면 전체 명령 목록이 나옵니다.

**종료 코드:**

| 코드 | 뜻 |
|---|---|
| 0 | 성공 |
| 1 | 실패. 바뀐 것이 없거나, 이전 계정으로 되돌리고 확인까지 마침 |
| 2 | 되돌렸지만 Claude 로그에서 확인하지 못함 |
| 3 | Code 세션이 실행 중. `--yes` 를 붙여야 함 |
| 4 | 복구 필요. `recover` 실행 |
| 64 | 알 수 없는 명령이나 빠진 인자. 사용법을 출력함 |

`usageswitch://switch?id=<account-id>` 링크로 다른 도구에서도 같은 전환을 할 수 있습니다. 링크로 시작한 전환은 항상 확인을 묻고, 기본 버튼은 취소입니다.

## 전환 동작

1. **사전 점검**
   - 저장본이 온전한지(SHA-256)
   - 쿠키 DB 형식이 호환되는지
   - 디스크 여유가 8GB 이상인지
   - Claude 업데이트가 설치 중이 아닌지
2. Claude 를 자동으로 다시 띄우는 사용자 LaunchAgent(keep-alive 에이전트 등)를 잠시 멈춥니다. 끝나면 되돌리며, plist 는 고치지 않습니다.
3. Claude 를 정상 종료합니다. 강제 종료는 하지 않습니다.
4. 나가는 계정의 쿠키를 다시 저장해, 갱신된 로그인을 잃지 않게 합니다. 첫 전환 때는 원래 파일의 백업도 만듭니다.
5. Claude 의 `Cookies` DB 를 대상 계정의 사본으로 원자적으로 교체합니다.
6. `config.json` 의 `lastKnownAccountUuid` 를 맞추고 캐시된 토큰을 지워, Claude 가 새로 발급받게 합니다.
7. 깨끗한 환경으로 Claude 를 다시 실행합니다. Claude 로그에 대상 계정이 찍히는지 확인하고, 이후 20초 동안 지켜봅니다.
8. 어느 단계든 실패하면 이전 파일을 그대로 되돌리고 다시 실행해, 이전 계정까지 확인합니다.

모든 단계는 실행 전에 기록(journal)됩니다. 전환 도중 UsageSwitch 나 Mac 이 멈춰도 다음 실행 때 복구합니다. 명령줄의 `recover` 로도 복구할 수 있습니다.

## 개인정보와 안전

UsageSwitch 는 스스로 네트워크에 연결하지 않으며, 분석이나 원격 측정도 없습니다.

인터넷 연결은 두 경우뿐이고, 둘 다 브라우저에서 일어납니다.
- **업데이트 확인…** 은 브라우저에서 웹 페이지를 엽니다.
- Codex 로그인은 Codex CLI 가 브라우저에서 진행합니다.

자세한 내용은 [PRIVACY.md](PRIVACY.md)(영문)에 있습니다.

- **서버 로그아웃 없음**: 서버 세션이 폐기되므로 로그아웃으로 전환하지 않습니다.
- **로그인 정보를 복호하거나 출력하지 않음**
  - 저장본은 Claude 가 저장한 그대로 암호화된 쿠키 DB 입니다.
  - 키체인은 읽지 않습니다.
- **쓰는 곳**
  - 데이터 폴더 `~/Library/Application Support/com.jaysong.usageswitch/` (본인만 읽을 수 있음)
  - 전환할 때 Claude 의 `Cookies` 파일과 `config.json`
- **쓰지 않는 곳**: `~/.claude`(Claude Code CLI 로그인), 다른 앱의 데이터, 키체인

## 한계

- Claude Desktop 의 내부 파일(쿠키 DB, config 키, 로그 문구)에 의존합니다. Claude 업데이트로 형식이 바뀌면, UsageSwitch 가 업데이트될 때까지 전환이 안전하게 실패하고 롤백됩니다.
- 저장된 로그인은 claude.ai 세션이 만료되기 전(약 4주)에 한 번 이상 써야 합니다. 그러지 않으면 **재로그인 필요**로 표시됩니다.
- Claude Desktop 인스턴스 하나만 전환합니다. 여러 Claude 를 동시에 띄우지는 않습니다.
- 키체인에 로그인을 저장하는 Codex 홈(`cli_auth_credentials_store = "keyring"`)은 로그아웃으로 보일 수 있습니다.

## 제거

1. 원하면 Codex 탭에서 추가한 Codex 계정을 제거합니다(로그아웃됨).
2. ⚙︎ › **로그인 시 자동 실행**을 끄고, UsageSwitch 를 종료한 뒤 휴지통으로 옮깁니다.
3. `~/Library/Application Support/com.jaysong.usageswitch/` 를 지웁니다.
   - 저장된 로그인, 이름, 설정이 들어 있습니다.
   - UsageSwitch 에서 추가한 Codex 홈도 여기 있습니다.
4. 원하면 `defaults delete com.jaysong.usageswitch` 로 창 위치 같은 환경설정도 지웁니다.

## 소스에서 빌드

macOS 15 이상에서 Xcode 16 이상(Swift 6)이 필요합니다.

```bash
swift build
./scripts/test.sh              # 테스트와 커버리지
./scripts/bundle.sh            # build/UsageSwitch.app (유니버설)
python3 scripts/check-l10n.py  # 모든 언어에 모든 문자열이 있는지 검사
```

- `bundle.sh` 는 `SIGN_IDENTITY`(Developer ID Application 인증서)로 서명하고, 없으면 ad-hoc 서명으로 대신합니다.
- `scripts/notarize.sh` 는 `notarytool` 키체인 프로필로 공증합니다.

## 관련 프로젝트

다음 오픈소스 프로젝트에서 아이디어를 참고했습니다. 코드는 복사하지 않았습니다.

- [claudepot-app](https://github.com/xiaolai/claudepot-app)
- [claude-desktop-accounts](https://github.com/5eanxlee/claude-desktop-accounts)
- [Swivel](https://github.com/jspanji/Swivel)
- [claude-graft](https://github.com/aaditya-v-more/claude-graft)

## 고지

UsageSwitch 는 독립 프로젝트입니다. Anthropic 이나 OpenAI 와 제휴하지 않았고, 그 보증이나 지원을 받지 않습니다. Claude 는 Anthropic 의, Codex 는 OpenAI 의 제품입니다. 각 계정은 해당 서비스 약관에 맞게 사용하세요.

## 라이선스

[MIT](LICENSE) © 2026 Jay Song
