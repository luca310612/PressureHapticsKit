import unittest

from http.client import HTTPConnection
from pathlib import Path
import threading

from gnat.viewer import PAGE, VIEWER_SCRIPT, _ViewerHTTPServer, _ViewerState

VIEWER_JS = Path(__file__).resolve().parents[1] / "src" / "gnat" / "web" / "viewer.js"


class ViewerTests(unittest.TestCase):
    def test_page_declares_demo_backend_and_serialized_frame_polling(self) -> None:
        javascript = VIEWER_JS.read_text(encoding="utf-8")
        self.assertIn("__GNAT_BACKEND_LABEL__", PAGE)
        self.assertIn("<script src=\"/viewer.js\"></script>", PAGE)
        self.assertIn('class="eye-strip"', PAGE)
        self.assertIn('class="signal-panel neural-panel"', PAGE)
        self.assertIn('id="fire" onclick="command(\'/fire\')">MOVE OBJECT</button>', PAGE)
        self.assertEqual(PAGE.count('id="left-eye"'), 1)
        self.assertEqual(PAGE.count('id="right-eye"'), 1)
        self.assertIn('src="/frame/main.jpg?token=__GNAT_TOKEN__"', PAGE)
        self.assertIn('src="/frame/left.jpg?token=__GNAT_TOKEN__"', PAGE)
        self.assertIn('src="/frame/right.jpg?token=__GNAT_TOKEN__"', PAGE)
        self.assertIn("async function refreshFrames()", javascript)
        self.assertIn("setTimeout(refreshFrames, 33)", javascript)
        self.assertIn("FRAME STALE", javascript)
        self.assertIn("X-Gnat-Token", javascript)

    def test_viewer_script_is_served_with_runtime_token(self) -> None:
        server = _ViewerHTTPServer(_ViewerState(lock=threading.Lock()))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            connection = HTTPConnection(*server.server_address)
            connection.request("GET", "/viewer.js")
            response = connection.getresponse()
            body = response.read().decode("utf-8")
            connection.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

        self.assertEqual(response.status, 200)
        self.assertNotIn("__GNAT_TOKEN__", body)
        self.assertIn(server.auth_token, body)
        self.assertIn("withToken", body)

    def test_protected_requests_accept_query_token_and_reject_missing_token(self) -> None:
        state = _ViewerState(
            lock=threading.Lock(),
            main_jpeg=b"main",
            brain_state={"ready": True},
        )
        server = _ViewerHTTPServer(state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            token = server.auth_token
            host, port = server.server_address

            authorized = HTTPConnection(host, port)
            authorized.request("GET", f"/frame/main.jpg?token={token}")
            authorized_response = authorized.getresponse()
            authorized_body = authorized_response.read()
            authorized.close()

            missing = HTTPConnection(host, port)
            missing.request("GET", "/frame/main.jpg")
            missing_response = missing.getresponse()
            missing_response.read()
            missing.close()

            command = HTTPConnection(host, port)
            command.request("POST", f"/fire?token={token}")
            command_response = command.getresponse()
            command_body = command_response.read().decode("utf-8")
            command.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

        self.assertEqual(authorized_response.status, 200)
        self.assertEqual(authorized_body, b"main")
        self.assertEqual(missing_response.status, 403)
        self.assertEqual(command_response.status, 200)
        self.assertIn("横移動を開始しました", command_body)

if __name__ == "__main__":
    unittest.main()
