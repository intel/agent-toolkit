# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Run a script with the given hostnames resolved to the gateway address.

Usage: run_via_gateway.py <gateway-ip> <host,.suffix,...> <script> [args...]
An entry starting with "." matches every host under it (E2B's per-sandbox
hosts). For validation from a host without DNS for the platform domain;
nothing else is redirected, and no system file is changed.
"""
import runpy
import socket
import sys

gateway, hosts = sys.argv[1], sys.argv[2].split(",")


def _ours(host):
    return any(host == h or (h.startswith(".") and str(host).endswith(h)) for h in hosts)


_getaddrinfo = socket.getaddrinfo
socket.getaddrinfo = lambda host, *a, **k: _getaddrinfo(gateway if _ours(host) else host, *a, **k)
sys.argv = sys.argv[3:]
runpy.run_path(sys.argv[0], run_name="__main__")
