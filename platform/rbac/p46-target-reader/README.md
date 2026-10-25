# #46 배포 SA 식별 조회 최소 권한 — 적용·회수 인계

사용자 결정: 2026-10-25 KST “권한을 상승해줘” → “중앙으로 권한 부여하자” → “하영님께 준비한 최소 권한 적용을 요청해줘”.

권욱 Red Hat 계정에서는 대상 클러스터가 보이지만 Cluster Roles and Access의 Add user가 비활성화되어 있었다. 클러스터 Owner는 HaYeoung Lee이다. AWS IAM 변경으로 대체하지 않는다.

## 범위와 실행 조건

- 작업자: 하영 또는 해당 클러스터의 기존 관리 권한을 가진 운영자. 타인 암호·토큰을 공유하지 않는다.
- 대상: `fds-rosa-hcp`, Cluster UUID `37eecf03-b7bc-45e1-8089-5a14a47fccd9`, `fds-app` UID `222bf961-73d9-4743-972f-2d44da216af2`.
- 수혜자: 기존 SA `ci-cd/fds-deployer`, UID `6a4c1f9f-1291-4f1d-b999-b4dbc5d179c2`와 사용자 `gwonuk`이다. 사용자본인의두조회상향요청을반영하되임시cluster-admin은영구화하지않는다.
- 새 객체: ClusterRole `fds-p2-delivery-target-reader`1개와 ClusterRoleBinding2개(SA용동일이름, User용 `fds-p2-delivery-target-reader-gwonuk`)다. 기존 사람·SA·Role/Binding을 수정하지 않는다. User추가도같은get2개뿐이다.
- 추가 권한: `config.openshift.io/clusterversions`의 이름 `version` get, core `namespaces`의 이름 `fds-app` get. list/watch/write/Secret/exec/다른 namespace/cluster-admin은 manifest에 없다.
- 정상 적용 후 추가 앱배포·SA TokenRequest·새 RUN은 이번 변경에 포함하지 않는다. 기존 A1 `PREFLIGHT_DENIED`의 직접 원인은 미확정이므로 “전체 차단 해소”로 표시하지 않는다.
- 코드/실행 manifest이므로 PR의 정확한 HEAD에 작성자 외 독립 검토를 남기고 검토된 SHA를 사용한다. 본 사용자 결정으로 위2건 적용 범위는 승인되었으며 같은 변경에 대해 권욱에게 반복 GO를 요청하지 않는다. 새 사람용 관리자 권한이 필요하면 이2건 변경과 구분한다.

## 실행 위치·사전 확인

하영님의 기존 승인된 ROSA 관리 CLI 세션에서 실행한다. `oc`는 기존 검증된 버전을 사용하며 kubeconfig/token/암호를 증적에 넣지 않는다. 실행 명령·RC·KST·소스 SHA를 작업자 전용0700 폴더에 기록한다.

```sh
oc whoami
oc whoami --show-server
oc get clusterversion version -o jsonpath='{.spec.clusterID}{"\n"}'
oc get namespace fds-app -o jsonpath='{.metadata.uid}{"\n"}'
oc get serviceaccount fds-deployer -n ci-cd -o jsonpath='{.metadata.uid}{"\n"}'
oc get clusterrole fds-p2-delivery-target-reader
oc get clusterrolebinding fds-p2-delivery-target-reader
oc get clusterrolebinding fds-p2-delivery-target-reader-gwonuk
```

서버는 `https://api.fds-rosa-hcp.khht.p3.openshiftapps.com:443`이고 위 UUID/UID가 일치해야 한다. 처음 네 조회 실패·불일치는 STOP이다. 마지막 두 조회는 `NotFound`가 기대이며 Forbidden/timeout을 NotFound로 해석하지 않는다. 이름이 이미 존재하면 overwrite/apply/force 없이 기존 UID·정의를 읽어 인수한다. 비중첩을 확인한다.

## 생성·readback

PR에서 검토된 `p46-target-reader-role.yaml`, `p46-target-reader-binding.yaml`을 같은 SHA로 받는다.

```sh
oc create --dry-run=server -f p46-target-reader-role.yaml -o yaml
oc create -f p46-target-reader-role.yaml -o json
oc get clusterrole fds-p2-delivery-target-reader -o json
oc create --dry-run=server -f p46-target-reader-binding.yaml -o yaml
oc create -f p46-target-reader-binding.yaml -o json
oc get clusterrolebinding fds-p2-delivery-target-reader -o json
```

사용자binding도동일하게 `oc create --dry-run=server -f p46-target-reader-gwonuk-binding.yaml -o yaml`→`oc create -f p46-target-reader-gwonuk-binding.yaml -o json`→`oc get clusterrolebinding fds-p2-delivery-target-reader-gwonuk -o json`으로확인한다.

명령마다 RC를 확인한다. Role은2규칙만, Binding은위 roleRef와SA1개만인지 읽기 대조하고 생성 UID 두 개를 보존한다. 중간 실패 시 새 Role을 남겼는지 읽기 확인하고 자기 생성분만 아래 순서로 정리한다. 자동 재생성·기존 객체 덮어쓰기는 하지 않는다.

기존 관리자가 SubjectAccessReview를 만들 수 있으면 SA 토큰 발급 없이 두 실제 권한을 각각 확인한다. API review는 권한 조회이며 권한을 부여하는 객체가 아니다. 아래 name/group/resource를 두 승인 대상에 맞춰 각각1회 사용한다.

```yaml
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: system:serviceaccount:ci-cd:fds-deployer
  groups:
    - system:authenticated
    - system:serviceaccounts
    - system:serviceaccounts:ci-cd
  resourceAttributes:
    group: config.openshift.io
    version: v1
    resource: clusterversions
    name: version
    verb: get
```

두 번째는 `group: ""`, `version: v1`, `resource: namespaces`, `name: fds-app`, `verb: get`이다. cluster-scope이므로 namespace 속성을 넣지 않는다. `oc create -f review.yaml -o json`의 `status.allowed=true`, `denied` 미설정/false, `evaluationError` 미설정/빈값이 기대다. 조회 권한이 없으면 새 SA 자격을 발급하지 말고 “정의 readback 완료·실효 조회 미확인”으로 회신한다. 이2건 PASS를 SA 전체 최소권한·앱배포/전체 preflight PASS로 확대하지 않는다.

## 회수·부분 실패 복구

10/26 최종 정리·보고12:00 전, 소비가 끝난 뒤 회수한다. 최종 정리 담당 하영, 권욱 인수. `fds-hybrid/expires`는 기록이며 자동 TTL 회수가 아니다. RBAC는 이름으로 SA를 참조하므로 SA가 삭제·재생성되면 새 UID에도 적용될 수 있다. 작업 전·후 UID 일치를 확인하며 이 Binding을 다른 SA에 재사용하지 않는다.

삭제 직전 현재 UID/정의가 이번 생성 readback과 같은지 확인하고, 다르면 STOP한다. 다른 동시 writer가 없는 상태에서 이번 객체만 정리한다. 다음 CLI 조회와 삭제는 하나의 원자적 요청은 아니다.

```sh
oc get clusterrolebinding fds-p2-delivery-target-reader -o json
oc delete clusterrolebinding fds-p2-delivery-target-reader
oc get clusterrolebinding fds-p2-delivery-target-reader
```

두Binding의자기UID/정의를대조해각각삭제·부재(`NotFound`)를확인한뒤, 동일 Role을 참조하는 다른 Binding이 없고 Role UID/정의가 자기 생성분과 동일한지 확인해 Role을 삭제하고 부재를 확인한다. 기본 bootstrap/human RoleBinding·다른 사용자 권한은 정리하지 않는다. 회수 시각·RC·부재 확인을 #55에 연결한다.

## 최종 CI/CD 일괄 대조

[PERMISSIONS.md](PERMISSIONS.md)의 전체 권한표와 `p46-effective-permissions.yaml`의16개권한을 같은 회신에서 확인한다. 2get만조회하고배포쓰기/본인review권한확인을생략하지않는다. 이미허용된권한은중복추가하지않는다.

## 회신 양식

기존 #46 댓글에 다음 값만 남긴다: 검토/적용 SHA, 실행자, KST, 대상 UUID/SA UID, 새 Role/Binding UID, 두 규칙 readback, 두 실효 조회 결과 또는 미확인 사유, 임시 작업자 권한 회수 여부(해당 시), #55 회수 인수. raw 자격·kubeconfig·Secret은 올리지 않는다.

STATIC/REVIEW/MERGE/RUNTIME을 구분한다. 이 문서 작성 시 실제 권한 변경은 아직 미실행이다.


사용자요청추가: 임시cluster-admin회수후본인새세션에서두get이허용되고 `oc auth can-i '*' '*'`가no인지확인한다. 기존namespace임시admin과별개이다.
