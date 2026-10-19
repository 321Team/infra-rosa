#!/usr/bin/env python3
"""창 B 전용 NetworkPolicy가 cold-pull 키트와 맞는지 오프라인으로 본다(클러스터 호출 없음).

사용: check_window_b_np.py <20-coldpull-probe-egress.yaml> <platform/netpol/03-allow-egress-onprem.yaml> <coldpull-kit-dir>
- 키트의 실제 coldpull_tool.podspec()으로 tool·pull Pod 사양을 만들어 선택자와 대조한다.
  tool Pod는 선택되고 pull Pod는 선택되지 않아야 한다. #7 03은 tool Pod를 선택하지 않아야 한다(이 정책이 필요한 이유).
- 허용 tuple은 키트 kit.env의 IMAGE_HOST·HARBOR_PORT·NEG_HARBOR_PORTS·P3_TARGET_HOST/PORT와 정확히 같아야 한다.
- Egress만, 대상은 /32 ipBlock만(namespaceSelector·podSelector·except·포트 범위 없음), Ingress 규칙 없음.
종료 코드: 0 PASS, 1 STOP, 2 사용법 오류.
"""
import importlib.util
import os
import re
import sys

import yaml


def load_kit(kit_dir):
    spec = importlib.util.spec_from_file_location("coldpull_tool", os.path.join(kit_dir, "coldpull_tool.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    env = {}
    for line in open(os.path.join(kit_dir, "kit.env"), encoding="utf-8"):
        m = re.match(r'^([A-Z0-9_]+)="([^"]*)"', line)
        if m:
            env[m.group(1)] = m.group(2)
    return mod, env


def selects(selector, labels):
    if set(selector) - {"matchLabels"}:
        raise ValueError(f"matchLabels 외 선택자 사용: {sorted(selector)}")
    return all(labels.get(k) == v for k, v in (selector.get("matchLabels") or {}).items())


def tuples(policy):
    out, errs = set(), []
    for i, rule in enumerate(policy["spec"].get("egress") or []):
        if set(rule) - {"to", "ports"}:
            errs.append(f"egress[{i}]: to/ports 외 키 {sorted(set(rule) - {'to', 'ports'})}")
        peers, ports = rule.get("to") or [], rule.get("ports") or []
        if not peers or not ports:
            errs.append(f"egress[{i}]: 대상 또는 포트가 비어 있음(전체 허용이 됨)")
        for p in peers:
            ib = p.get("ipBlock") if set(p) == {"ipBlock"} else None
            if not ib or set(ib) != {"cidr"} or not re.fullmatch(r"\d+\.\d+\.\d+\.\d+/32", ib["cidr"]):
                errs.append(f"egress[{i}]: /32 ipBlock만 허용(받은 값 {p})")
                continue
            for pt in ports:
                if set(pt) - {"protocol", "port"} or pt.get("protocol") != "TCP" or not isinstance(pt.get("port"), int):
                    errs.append(f"egress[{i}]: TCP 단일 포트만 허용(받은 값 {pt})")
                    continue
                out.add((ib["cidr"].split("/")[0], pt["port"]))
    return out, errs


def check(policy, onprem03, mod, env):
    errs = []
    if policy.get("kind") != "NetworkPolicy" or policy.get("apiVersion") != "networking.k8s.io/v1":
        errs.append("kind/apiVersion 다름")
    spec = policy.get("spec") or {}
    if spec.get("policyTypes") != ["Egress"]:
        errs.append(f"policyTypes는 [Egress]만: {spec.get('policyTypes')}")
    if "ingress" in spec:
        errs.append("ingress 규칙이 있음")
    ns = policy["metadata"].get("namespace")
    base = {"namespace": ns, "run": "coldpull-mock-run-000001", "node": "ip-10-20-10-11", "image": "x@sha256:" + "a" * 64}
    tool = mod.podspec("pod-tool", dict(base, case="tool", name="tool", ca_configmap="cm"))
    pull = mod.podspec("pod-pull", dict(base, case="pull", name="pull", pull_secret="s"))
    tl, pl = tool["metadata"]["labels"], pull["metadata"]["labels"]
    try:
        if not selects(spec.get("podSelector") or {}, tl):
            errs.append(f"키트 tool Pod 라벨 {tl}을 선택하지 못함")
        if selects(spec.get("podSelector") or {}, pl):
            errs.append(f"pull Pod 라벨 {pl}까지 선택함(범위 초과)")
        if not (spec.get("podSelector") or {}).get("matchLabels"):
            errs.append("podSelector가 비어 있음(Namespace 전체 선택)")
    except ValueError as e:
        errs.append(str(e))
    if selects(onprem03["spec"]["podSelector"], tl):
        errs.append("#7 03이 이미 tool Pod를 선택함 — 이 정책이 중복일 수 있음(재검토)")
    if tool["metadata"]["namespace"] != ns:
        errs.append("namespace가 키트 Pod와 다름")
    got, terrs = tuples(policy)
    errs += terrs
    want = {(env["IMAGE_HOST"], int(env["HARBOR_PORT"]))}
    want |= {(env["IMAGE_HOST"], int(p)) for p in env["NEG_HARBOR_PORTS"].split()}
    want.add((env["P3_TARGET_HOST"], int(env["P3_TARGET_PORT"])))
    if got != want:
        errs.append(f"허용 tuple이 키트 시험 대상과 다름: 정책 {sorted(got)} / 키트 {sorted(want)}")
    return errs, tl, sorted(want)


def main(argv):
    if len(argv) != 4:
        print(__doc__)
        return 2
    policy = yaml.safe_load(open(argv[1], encoding="utf-8"))
    onprem03 = yaml.safe_load(open(argv[2], encoding="utf-8"))
    mod, env = load_kit(argv[3])
    errs, tl, want = check(policy, onprem03, mod, env)
    print(f"INFO tool Pod 라벨(키트 podspec): {tl}")
    print(f"INFO 키트 시험 tuple: {want}")
    for e in errs:
        print("STOP", e)
    if not errs:
        print("PASS window-b policy: selector·tuple이 키트와 일치")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
