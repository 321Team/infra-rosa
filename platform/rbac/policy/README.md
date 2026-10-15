# 플랫폼 기본 binding 승인 목록 (infra-rosa#5, AFTER-CREATE)

`platform-defaults.approved.tsv`는 **아직 없습니다.** 실제 ROSA 클러스터의 첫 bootstrap 증적을 보고 PR 리뷰로 만듭니다.

- **용도**: `bootstrap/classify-access-paths.sh`가 `system:authenticated(:oauth)` 그룹에만 붙은 binding을 "플랫폼 기본"으로 인정하는 유일한 근거입니다.
- **없으면**: 그런 binding은 `PENDING_POLICY`로 분류됩니다. bootstrap 래퍼는 회수까지 정상으로 마친 뒤 **rc=3**으로 끝나고, `post-revoke-check.sh`는 이 파일이 생길 때까지 STOP합니다.

## 형식 (TSV, `#`로 시작하는 줄은 주석)

```
scope	binding	roleRef.kind	roleRef.name	subjects	rules_sha256
cluster	self-provisioners	ClusterRole	self-provisioner	Group:system:authenticated:oauth	<64자리 hex>
```

`rules_sha256`은 수집된 `clusterrole-<name>.json`을 아래처럼 정규화한 값입니다. 분류기와 같은 계산입니다.

```bash
jq -cS '{rules: (.rules // []), aggregationRule: (.aggregationRule // null)}' clusterrole-<name>.json | sha256sum
```

## 만드는 절차
1. 첫 bootstrap 증적의 `10b-path-review.tsv`에서 `PENDING_POLICY` 행과 `10b-inventory/clusterrole-*.json`을 근거로 행을 **제안**합니다.
2. 각 행이 정말 저권한 플랫폼 기본인지 규칙 원문과 함께 PR로 리뷰받습니다. **수집한 값을 그대로 자동 승인하지 않습니다.**
3. 병합 뒤 `post-revoke-check.sh`가 저장된 증적을 오프라인으로 재판정합니다.
4. 이름이 같아도 규칙이 바뀌면(해시 불일치) STOP합니다. 목록 변경은 다시 리뷰를 거칩니다.
