import importlib.util
import os

import pytest

sdk_conftest_path = os.path.join(
    os.path.dirname(__file__), "..", "..", "python", "tests", "conftest.py"
)
spec = importlib.util.spec_from_file_location("sdk_conftest", sdk_conftest_path)
sdk_conftest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk_conftest)
MockUDSServer = sdk_conftest.MockUDSServer


@pytest.fixture
def mock_uds_server(tmp_path):
    sock_path = str(tmp_path / "zb-test.sock")
    server = MockUDSServer(sock_path)
    server.start()
    yield server
    server.close()
