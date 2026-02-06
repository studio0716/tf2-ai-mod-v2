"""
TF2 IPC Client - Sends commands to Transport Fever 2 via file-based IPC.

Usage:
    from ipc_client import IPCClient
    ipc = IPCClient()
    resp = ipc.send('query_game_state')
    print(resp)  # {'status': 'ok', 'data': {'year': '1914', 'money': '187521196', ...}}
"""

import json
import os
import time
import uuid
from typing import Any, Dict, Optional


CMD_FILE = "/tmp/tf2_cmd.json"
RESP_FILE = "/tmp/tf2_resp.json"
IPC_LOG = "/tmp/tf2_simple_ipc.log"


class IPCClient:
    """File-based IPC client for Transport Fever 2."""

    def __init__(self, cmd_file: str = CMD_FILE, resp_file: str = RESP_FILE):
        self.cmd_file = cmd_file
        self.resp_file = resp_file

    def send(self, command: str, params: Dict[str, Any] = None,
             timeout: float = 30.0) -> Optional[Dict]:
        """
        Send a command to TF2 and wait for the response.

        Args:
            command: IPC command name (e.g., 'query_game_state', 'build_industry_connection')
            params: Command parameters (all values will be stringified for Lua)
            timeout: Max seconds to wait for response

        Returns:
            Response dict with 'status', 'data'/'message', 'id' keys.
            None if timeout.
        """
        request_id = uuid.uuid4().hex[:8]

        # CRITICAL: Stringify all values for Lua's JSON parser
        str_params = self._stringify(params or {})

        cmd = {
            "id": request_id,
            "cmd": command,
            "ts": str(int(time.time() * 1000)),
            "params": str_params
        }

        # Clear stale response
        if os.path.exists(self.resp_file):
            os.remove(self.resp_file)

        # Write command atomically (tmp + rename prevents partial reads)
        tmp_file = self.cmd_file + ".tmp"
        with open(tmp_file, 'w') as f:
            json.dump(cmd, f)
        os.rename(tmp_file, self.cmd_file)

        # Poll for response
        start = time.time()
        while time.time() - start < timeout:
            if os.path.exists(self.resp_file):
                try:
                    with open(self.resp_file) as f:
                        resp = json.load(f)
                    if resp.get("id") == request_id:
                        os.remove(self.resp_file)
                        return resp
                except (json.JSONDecodeError, IOError):
                    pass
            time.sleep(0.1)

        return None  # Timeout

    def ping(self, timeout: float = 5.0) -> bool:
        """Check if the game is responding."""
        resp = self.send("ping", timeout=timeout)
        return resp is not None and resp.get("status") == "ok"

    def _stringify(self, data: Any) -> Any:
        """Recursively convert all values to strings for Lua compatibility."""
        if isinstance(data, dict):
            return {str(k): self._stringify(v) for k, v in data.items()}
        elif isinstance(data, list):
            return [self._stringify(v) for v in data]
        elif data is None:
            return "null"
        elif isinstance(data, bool):
            return "true" if data else "false"
        else:
            return str(data)


# Singleton
_ipc = None

def get_ipc() -> IPCClient:
    """Get the singleton IPC client instance."""
    global _ipc
    if _ipc is None:
        _ipc = IPCClient()
    return _ipc


# --- Convenience functions ---

def query_game_state() -> Dict:
    return get_ipc().send('query_game_state')

def query_lines() -> Dict:
    return get_ipc().send('query_lines')

def query_industries() -> Dict:
    return get_ipc().send('query_industries')

def query_towns() -> Dict:
    return get_ipc().send('query_towns')

def query_town_demands() -> Dict:
    return get_ipc().send('query_town_demands')

def set_speed(speed: int) -> Dict:
    return get_ipc().send('set_speed', {'speed': speed})

def build_industry_connection(industry1_id: int, industry2_id: int) -> Dict:
    return get_ipc().send('build_industry_connection', {
        'industry1_id': industry1_id,
        'industry2_id': industry2_id
    })

def build_cargo_to_town(industry_id: int, town_id: int, cargo: str) -> Dict:
    return get_ipc().send('build_cargo_to_town', {
        'industry_id': industry_id,
        'town_id': town_id,
        'cargo': cargo
    })

def add_vehicle_to_line(line_id: int, cargo_type: str = None,
                         wagon_type: str = None) -> Dict:
    params = {'line_id': line_id}
    if cargo_type:
        params['cargo_type'] = cargo_type
    if wagon_type:
        params['wagon_type'] = wagon_type
    return get_ipc().send('add_vehicle_to_line', params)

def set_line_load_mode(line_id: int, mode: str = "load_if_available") -> Dict:
    return get_ipc().send('set_line_load_mode', {
        'line_id': line_id,
        'mode': mode
    })

def set_line_all_terminals(line_id: int) -> Dict:
    return get_ipc().send('set_line_all_terminals', {'line_id': line_id})


if __name__ == "__main__":
    """Quick connectivity test."""
    ipc = IPCClient()
    print("Pinging TF2...")
    if ipc.ping():
        print("Connected!")
        state = ipc.send('query_game_state')
        if state:
            d = state.get('data', {})
            print(f"Year: {d.get('year')}, Money: ${int(d.get('money', 0)):,}, Speed: {d.get('speed')}")
    else:
        print("Game not responding. Is TF2 running with the mod installed?")
