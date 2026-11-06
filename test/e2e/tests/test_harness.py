import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from engine import endpoints, httpc, runner, spec  # noqa: E402


class EndpointParserTest(unittest.TestCase):
    def test_parses_prefix_handlers_and_routes(self):
        source = """
@server (
	prefix: /api/v1
)
service app-api {
	@doc "健康检查"
	@handler Ping
	get /ping (PingReq) returns (PingResp)
}
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "app.api"
            path.write_text(source, encoding="utf-8")
            parsed = endpoints.parse_api_file(path, "app")

        self.assertEqual(len(parsed), 1)
        self.assertEqual(parsed[0]["operation"], "app:Ping")
        self.assertEqual(parsed[0]["method"], "GET")
        self.assertEqual(parsed[0]["path"], "/api/v1/ping")
        self.assertEqual(parsed[0]["doc"], "健康检查")

    def test_collects_real_contract(self):
        inventory = endpoints.collect()
        operations = inventory["operations"]

        self.assertGreaterEqual(inventory["count"], 100)
        self.assertEqual(operations["app:Ping"]["path"], "/api/v1/ping")
        self.assertEqual(operations["app:PasswordLogin"]["method"], "POST")
        self.assertIn("app:GetUnreadCount", operations)


class DeviceHeadersTest(unittest.TestCase):
    def test_signs_device_triplet(self):
        headers = httpc.device_headers("e2e-run-1", 1700000000)

        self.assertEqual(headers["X-Device-Id"], "e2e-run-1")
        self.assertEqual(headers["Timestamp"], "1700000000")
        self.assertEqual(
            headers["X-Device-Token"],
            hashlib.sha256(b"e2e-run-11700000000").hexdigest(),
        )


class SafetyTest(unittest.TestCase):
    def test_first_matching_rule_wins(self):
        safety = {
            "rules": [
                {"match": "app:PasswordLogin", "level": "normal"},
                {"match": "app:Query*", "level": "normal"},
                {"match": "app:*", "level": "unimplemented"},
            ]
        }
        self.assertEqual(spec.classify(safety, "app:PasswordLogin"), "normal")
        self.assertEqual(spec.classify(safety, "app:QueryArticleList"), "normal")
        self.assertEqual(spec.classify(safety, "app:DeleteArticle"), "unimplemented")

    def test_unlisted_operation_is_unimplemented(self):
        self.assertEqual(spec.classify({"rules": []}, "app:Anything"), "unimplemented")

    def test_validate_rejects_unknown_and_destructive(self):
        inventory = {"operations": {"app:Known": {}}}
        with self.assertRaises(spec.SpecError):
            spec.validate_cases(inventory, {"rules": []}, [{"id": "x", "operation": "app:Unknown"}])
        with self.assertRaises(spec.SpecError):
            spec.validate_cases(
                inventory,
                {"rules": [{"match": "app:Known", "level": "destructive"}]},
                [{"id": "x", "operation": "app:Known"}],
            )


class CaseChainTest(unittest.TestCase):
    def test_render_path_substitutes_captured_variable(self):
        path = runner._render_path(
            "/api/v1/articles/:id/like",
            {"id": "{{article_id}}"},
            {"article_id": "42"},
        )
        self.assertEqual(path, "/api/v1/articles/42/like")

    def test_render_path_requires_captured_variable(self):
        with self.assertRaises(spec.SpecError):
            runner._render_path("/api/v1/articles/:id/like", {"id": "{{article_id}}"}, {})

    def test_capture_reads_dotted_path(self):
        variables = {}
        error = runner._capture(
            {"data": {"list": [{"id": 42}]}},
            {"article_id": "data.list.0.id"},
            variables,
        )
        self.assertIsNone(error)
        self.assertEqual(variables["article_id"], "42")

    def test_capture_reports_empty_list(self):
        error = runner._capture(
            {"data": {"list": []}},
            {"article_id": "data.list.0.id"},
            {},
        )
        self.assertIsNotNone(error)


class AssertionTest(unittest.TestCase):
    def test_checks_status_code_and_data_type(self):
        case = {"expect": {"status": 200, "code": "SUCCESS", "data_type": "object"}}
        self.assertIsNone(runner.assert_case(case, 200, {"code": "SUCCESS", "data": {}}))
        self.assertIn("http status", runner.assert_case(case, 500, {"code": "SUCCESS", "data": {}}))
        self.assertIn("code", runner.assert_case(case, 200, {"code": "ERROR"}))
        self.assertIn("data is", runner.assert_case(case, 200, {"code": "SUCCESS", "data": []}))


if __name__ == "__main__":
    unittest.main()
