#!/usr/bin/env python3
"""check_window_b_np.py 반례 시험. 실행: python3 platform/netpol/window-b/tests/test_check_window_b_np.py
키트 v5의 labels()/podspec()와 같은 모양의 합성 키트를 임시 폴더에 만들어 쓴다(실제 키트·클러스터 불필요)."""
import copy
import os
import sys
import tempfile
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
WB = os.path.dirname(HERE)
NETPOL = os.path.dirname(WB)
sys.path.insert(0, WB)
import check_window_b_np as c  # noqa: E402

FAKE_TOOL = '''
LABEL_PART = 'app.kubernetes.io/part-of'
LABEL_RUN = 'fds-coldpull-run'
def labels(kv):
    return {LABEL_PART: 'fds-coldpull', LABEL_RUN: kv['run'], 'fds-coldpull-case': kv['case']}
def podspec(kind, kv):
    return {'apiVersion': 'v1', 'kind': 'Pod',
            'metadata': {'name': kv['name'], 'namespace': kv['namespace'], 'labels': labels(kv)}, 'spec': {}}
'''
FAKE_ENV = 'IMAGE_HOST="10.1.93.54"\nHARBOR_PORT="443"\nNEG_HARBOR_PORTS="22 80"\nP3_TARGET_HOST="10.1.93.50"\nP3_TARGET_PORT="443"\n'


class T(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        open(os.path.join(cls.tmp, "coldpull_tool.py"), "w").write(FAKE_TOOL)
        open(os.path.join(cls.tmp, "kit.env"), "w").write(FAKE_ENV)
        cls.mod, cls.env = c.load_kit(cls.tmp)
        cls.pol = yaml.safe_load(open(os.path.join(WB, "20-coldpull-probe-egress.yaml"), encoding="utf-8"))
        cls.o3 = yaml.safe_load(open(os.path.join(NETPOL, "03-allow-egress-onprem.yaml"), encoding="utf-8"))

    def run_check(self, pol=None, o3=None, env=None):
        return c.check(pol or self.pol, o3 or self.o3, self.mod, env or self.env)[0]

    def mutate(self, fn):
        p = copy.deepcopy(self.pol); fn(p); return self.run_check(pol=p)

    def test_ok(self):
        self.assertEqual(self.run_check(), [])

    def test_case_label_removed_selects_pull(self):
        self.assertTrue(any("pull Pod" in e for e in self.mutate(lambda p: p["spec"]["podSelector"]["matchLabels"].pop("fds-coldpull-case"))))

    def test_wrong_label(self):
        self.assertTrue(any("선택하지 못함" in e for e in self.mutate(lambda p: p["spec"]["podSelector"]["matchLabels"].update({"fds-coldpull-case": "pull"}))))

    def test_empty_selector(self):
        self.assertTrue(self.mutate(lambda p: p["spec"].update({"podSelector": {}})))

    def test_match_expressions_refused(self):
        self.assertTrue(self.mutate(lambda p: p["spec"]["podSelector"].update({"matchExpressions": []})))

    def test_extra_port(self):
        self.assertTrue(any("tuple" in e for e in self.mutate(lambda p: p["spec"]["egress"][0]["ports"].append({"protocol": "TCP", "port": 8080}))))

    def test_missing_port80(self):
        self.assertTrue(any("tuple" in e for e in self.mutate(lambda p: p["spec"]["egress"][0]["ports"].pop(2))))

    def test_cidr_widened(self):
        self.assertTrue(any("/32" in e for e in self.mutate(lambda p: p["spec"]["egress"][0]["to"][0]["ipBlock"].update({"cidr": "10.1.93.0/24"}))))

    def test_namespace_selector_peer(self):
        self.assertTrue(any("/32" in e for e in self.mutate(lambda p: p["spec"]["egress"][1]["to"].append({"namespaceSelector": {}}))))

    def test_port_range(self):
        self.assertTrue(any("TCP 단일" in e for e in self.mutate(lambda p: p["spec"]["egress"][1]["ports"][0].update({"endPort": 500}))))

    def test_empty_ports_rule(self):
        self.assertTrue(any("비어 있음" in e for e in self.mutate(lambda p: p["spec"]["egress"].append({"to": [{"ipBlock": {"cidr": "1.1.1.1/32"}}]}))))

    def test_ingress_present(self):
        self.assertTrue(any("ingress" in e for e in self.mutate(lambda p: p["spec"].update({"ingress": []}))))

    def test_policy_types(self):
        self.assertTrue(self.mutate(lambda p: p["spec"].update({"policyTypes": ["Ingress", "Egress"]})))

    def test_kit_target_changed(self):
        env = dict(self.env, P3_TARGET_HOST="10.1.93.51")
        self.assertTrue(any("tuple" in e for e in self.run_check(env=env)))

    def test_03_already_selects_tool(self):
        o3 = copy.deepcopy(self.o3); o3["spec"]["podSelector"] = {"matchLabels": {"app.kubernetes.io/part-of": "fds-coldpull"}}
        self.assertTrue(any("중복" in e for e in self.run_check(o3=o3)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
