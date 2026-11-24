# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""E2B SDK smoke test against SPACE's E2B-compatible API (upstream docs/ecw.md)."""
import os

from e2b import Sandbox

sandbox = Sandbox.create(
    api_key=os.environ["E2B_API_KEY"],
    domain=os.environ["E2B_DOMAIN"],
    template="seed",
    timeout=120,
)
try:
    print(sandbox.commands.run("printf 'Hello from SPACE via E2B\\n'").stdout, end="")
finally:
    sandbox.kill()
