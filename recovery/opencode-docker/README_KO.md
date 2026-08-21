# OpenCode CLI + Docker OpenClaw 복구 경로

## 결론

이 경로는 OpenCode CLI를 **Windows PC의 로컬 실행자**로 사용합니다.

- OpenCode가 실행된 Windows 호스트에 이미 저장된 SSH config·SSH agent·개인 키를 재사용합니다.
- Docker는 실제 Pi를 제어하지 않습니다. Raspberry Pi ARM64용 payload의 Bash 문법과 OpenCode headless server만 격리 검증합니다.
- 실제 실행 전 원격 장치의 `/proc/device-tree/model`이 `Raspberry Pi 5`인지, `~/.openclaw/openclaw.json`과 `openclaw` CLI가 있는지 확인합니다.
- 비밀번호 로그인을 시도하지 않습니다.
- Tailscale 설정·ACL·로그인 상태를 변경하지 않습니다.
- 재부팅, 모르는 프로세스 종료, 두 번째 Telegram poller 생성은 하지 않습니다.

## 사용자 실행

ChatGPT에서 받은 비공개 payload 파일을 다음 위치에 둡니다.

```text
.private/pi-recovery.sh
.private/pi-recovery.manifest.json
```

그다음 Windows에서:

```text
RUN_WITH_OPENCODE.cmd
```

OpenCode 모델 인증이 막혔을 때만:

```text
RUN_DIRECT.cmd
```

## OpenCode TUI에서 직접 실행

프로젝트 루트에서 `opencode`를 열고 다음 명령을 실행합니다.

```text
/recover-openclaw
```

OpenCode는 로컬 또는 원격 서버 형태로 프로그래밍 제어할 수 있지만, Pi를 실제로 제어하려면 OpenCode가 실행되는 호스트 자체에 SSH·Raspberry Pi Connect 같은 실행 경로가 있어야 합니다.

## 결과

```text
receipts/opencode-windows-pi-recovery.json
```

성공:

```text
OPENCODE_RECOVERY_READY
```

연결 경로 없음:

```text
OPENCODE_RECOVERY_BLOCKED reason=no_authenticated_attested_pi5_ssh_target
```
