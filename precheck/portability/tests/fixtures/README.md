# pg03 MOCK fixtures

| 파일 | 출처 | SHA-256 |
|---|---|---|
| `oc-4.22.17-json-portable.out` | 2026-10-20 ROSA admission 실행(infra-rosa#6, RC11 STOP 회차) 원본 `run-admission-20261020T003831Z/json-portable.out` | `55fdbcdbcb1f7d739357f7db6327ae82fa7e041d8cf512279ea5c0fb8d289c29` |
| `oc-4.22.17-json-fixed.out` | 같은 회차 `json-fixed.out` | `31fe115032c54098135197bb24da8cc8b92c66794000898926eae1c9f9811227` |

- 원본 묶음: `run-admission-20261020T003831Z.tgz` SHA-256 `8ee207e9f12ace7e8def7628b6b1be3b112432df4659980bbd7d0c4a6d091ca5` (팀 공유 폴더, [#6 결과 6280562644](https://github.com/321Team/infra-rosa/issues/6#issuecomment-6280562644)).
- 내용: `oc` 4.22.17 `create --dry-run=client -o json`이 fds-msa `20ae161` `deploy/base` 렌더(SA 2, Deployment 2, Service 2, NetworkPolicy 3)를 **List가 아니라 JSON 객체 9개를 이어 붙여** 출력한 것입니다. Secret 값은 없고 `secretKeyRef`는 Secret 이름 참조뿐입니다.
- `tests/pg03-mock.sh`의 `real_fixture` 상황이 이 파일을 가짜 oc 응답으로 그대로 씁니다. 바이트를 고치지 않습니다.
