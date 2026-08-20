# GitHub ↔ Supabase Edge Function 동기화

이 저장소의 \`supabase/functions/manifest.json\`이 배포 대상과 엔트리포인트의 단일 원본입니다. GitHub Actions는 이 목록을 검증한 뒤, \`main\`에 반영된 변경 또는 수동 승인 실행에서만 Supabase CLI의 API 배포를 수행합니다.

## 1회 설정

저장소 관리자만 GitHub Actions secret에 Supabase Management access token을 저장합니다. 토큰 값은 커밋, Edge Function 환경변수, 로그에 넣지 않습니다.

\`\`\`bash
gh secret set SUPABASE_ACCESS_TOKEN --repo mnwersdfppa/no-cost-ai
\`\`\`

프로젝트 ref는 워크플로에 비밀이 아닌 값으로 고정되어 있습니다: \`dpllasnpfskyyyzebyal\`.

## 동작 경계

- Pull request: 소스·manifest 감사만 실행하며 원격 함수는 변경하지 않습니다.
- \`main\` push: manifest에 선언된 함수만 \`supabase functions deploy --use-api\`로 배포합니다.
- 수동 실행: \`deploy=true\`를 명시한 경우에만 배포합니다.
- GitHub Actions는 provider secret 값을 읽거나 Pi에 반환하지 않습니다.
- Edge Function의 런타임 secret은 Supabase 프로젝트 secret으로만 관리합니다.

배포가 실패하면 워크플로가 fail-closed로 중단되고, 배포 receipt가 생성되지 않습니다.
