#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only
"""camera-gamma.service shim: python3 -I drops the script dir from sys.path,
so put the installed package back on it and run the engine."""
import os
import sys

sys.path.insert(0, os.path.expanduser('~/.local/lib/camera-ae'))

from camera_ae.main import main  # noqa: E402

sys.exit(main(sys.argv[1:]))
