import json
import signal
import threading
import time
import unittest

from camera_ae import main as main_mod
from tests.fakes import FakePopen
from tests.test_engine import EXP, FRONT_ID, VTS, Harness
from tests.test_graph import BASE, FRONT, link

DUMP = (json.dumps(BASE + [link(200, FRONT_ID, 90)]) + '\n').encode()


class Runner:
    """Run main() in a thread against a FakePopen pw-dump and a Harness engine."""

    def __init__(self, h, evaluate=None):
        self.h = h
        self.popen = FakePopen()
        self.handlers = {}
        self.rc = None
        if evaluate is not None:
            h.engine.evaluate = evaluate
        self.t = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        self.rc = main_mod.main(
            [], {}, spawn=lambda *a, **k: self.popen,
            make_engine=lambda *a, **k: self.h.engine,
            install_signal=lambda sig, fn: self.handlers.__setitem__(sig, fn),
            pid_fn=lambda: None, log=lambda lvl, msg: self.h.logs.append((lvl, msg)))

    def start(self):
        self.t.start()
        return self

    def wait_session(self, timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if self.h.session() is not None:
                return self.h.session()
            time.sleep(0.01)
        raise AssertionError('no session')

    def join(self):
        self.t.join(10)
        assert not self.t.is_alive(), 'main did not return'
        return self.rc


class Main(unittest.TestCase):
    def test_sigterm_restores(self):
        h = Harness(front=(6248, 6256))
        r = Runner(h).start()
        r.popen.write(DUMP)
        r.wait_session()
        h.samplers[0].deliver()                       # running at a long frame
        h.xfers['front'].log.clear()
        h.samplers[0].die()                           # children die with us
        r.handlers[signal.SIGTERM](signal.SIGTERM, None)
        self.assertEqual(r.join(), 0)
        self.assertEqual(h.writes(), [EXP(3120), VTS(3128)])
        self.assertEqual(len(h.lines('stop node=33')), 1)

    def test_pwdump_eof_exits_nonzero(self):
        h = Harness()
        r = Runner(h).start()
        r.popen.write(DUMP)
        r.wait_session()
        r.popen.close()
        self.assertEqual(r.join(), 1)
        self.assertEqual(h.engine.sessions, {})

    def test_crash_in_evaluate_restores(self):
        h = Harness(front=(6248, 6256))
        real = h.engine.evaluate
        calls = []

        def flaky(cams):
            calls.append(1)
            if len(calls) == 2:
                raise RuntimeError('boom')
            return real(cams)

        r = Runner(h, evaluate=flaky).start()
        r.popen.write(DUMP)
        r.wait_session()
        h.samplers[0].deliver()
        h.xfers['front'].log.clear()
        r.popen.write(b'[]\n')
        end = time.monotonic() + 5
        while len(calls) < 3 and time.monotonic() < end:
            time.sleep(0.01)
        self.assertTrue(h.lines('boom'))
        self.assertIsNotNone(h.session())             # loop kept running
        r.popen.close()
        self.assertEqual(r.join(), 1)
        self.assertEqual(h.writes(), [EXP(3120), VTS(3128)])


if __name__ == '__main__':
    unittest.main()
