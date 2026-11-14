# UsageSwitch — 에이전트 공용 작업 규칙

이 저장소에서 일하는 모든 에이전트(Claude Code, Codex, Devin, Orca가 띄운 에이전트 등)가 따르는
단일 규칙이다. `CLAUDE.md`는 이 파일을 그대로 가져온다. 제품·디자인·개인정보의 정본은
`PRODUCT.md`, `DESIGN.md`, `PRIVACY.md`다.

## 작업 폴더는 하나

- 이 저장소의 main 체크아웃이 유일한 작업 폴더다. 저장소 밖에 복제본이나 작업 폴더를 새로 만들지 않는다.
- main 체크아웃은 항상 `main` 브랜치에 둔다. 작업은 브랜치마다 워크트리를 만들어서 한다.
  - Claude Code 세션: `.claude/worktrees/<이름>` (앱이 만든다)
  - 직접 만들 때: `git worktree add .claude/worktrees/<이름> -b <브랜치> origin/main`
  - Orca: 이 저장소가 등록돼 있고 외부 워크트리 표시가 켜져 있어서 `.claude/worktrees/*`도 Orca에 보인다.
    Orca에서 새 워크트리를 만들어도 되지만, 끝나면 `orca worktree rm`으로 정리한다.
  - Devin: main 체크아웃이나 위 워크트리 경로에서 `devin`을 실행한다.
- `/tmp` 같은 저장소 밖 임시 워크트리는 만들지 않는다. 끝난 워크트리는 `git worktree remove` 후 `git worktree prune`.

## 로컬 전용 영역 (커밋·삭제 금지)

| 경로 | 내용 | 무시 방식 |
|---|---|---|
| `docs/private/` | 계획 문서, `handoff/`의 최신 핸드오프 | `.gitignore` |
| `docs/evidence/` | 오딧·커버리지 근거 | `.gitignore` |
| `_local/releases/` | 지난 릴리스 산출물, 릴리스 노트, appcast 작업본 | `.git/info/exclude` |
| `_local/archive/` | 공개 전 저장소, 옛 로그와 오딧 실행 기록 | `.git/info/exclude` |

- `git clean -x`, `git clean -X`, `git clean -fdx`는 쓰지 않는다. 위 폴더가 통째로 지워진다.
  빌드 정리는 `rm -rf .build build`로 한다.
- 워크트리에는 위 폴더가 없다. 필요하면 main 체크아웃에서 읽는다:
  `dirname "$(git rev-parse --path-format=absolute --git-common-dir)"`.

## 브랜치와 PR

- `main`은 보호된다. 브랜치 → PR → CI(`macos` 잡) → squash 머지 순서를 지킨다.
  `gh pr merge` 등 `gh` 명령에는 `--repo deximple/usageswitch`를 붙인다.
- 커밋 메시지는 `<type>: <설명>` (feat, fix, refactor, docs, test, chore, perf, ci).
- 같은 파일을 두 에이전트가 동시에 고치지 않는다. 병행 작업이면 겹치는 파일을 PR 본문에 적고,
  충돌은 `main`으로 rebase 해서 푼다.
- 공개 저장소다. 개인 경로, 이메일, 계정·조직 ID, 토큰, 내부 맥락을 커밋하지 않는다.

## PR 전 검증

```bash
swift build
swift test                      # 커버리지 보고가 필요하면 scripts/test.sh
python3 scripts/check-l10n.py   # 문자열은 en/ko/ja/es/zh-Hans 5개 언어 모두에 넣는다
plutil -lint Resources/Info.plist
```

UI를 바꿨다면 데모 픽스처(`Sources/ClaudeSwitcher/Fixtures.swift`)로 라이트·다크와
여러 언어에서 직접 띄워 본다.

## 제품 원칙 (요약)

- 벤더 토큰을 직접 읽거나 쓰지 않는다. 벤더 CLI를 실행해서 그 답만 읽는다.
- 벤더 오류 문구는 사유로만 바꾸고 보관하지 않는다. 신원 정보가 섞일 수 있다.
- 상태를 바꾸는 벤더 동작(리셋 티켓 사용, 로그아웃, 계정 전환 등)을 앱이 스스로 하지 않는다.
- 오래됐거나 실패한 읽기를 현재 값처럼 보이지 않는다.

## 릴리스

절차와 함정은 `docs/private/handoff/`의 최신 핸드오프 문서에 있다. 공증은 사용자가 자기 터미널에서 실행한다.
