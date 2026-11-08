"""Test fakes shared by the sensor, engine and main tests."""
from camera_ae.sensor import I2C_M_RD


class FakeXfer:
    """An I2C bus with one 16-bit-addressed register file.

    A write message followed by a read message is an address-set + read;
    a lone write message writes its payload starting at its address.
    `log` records every write as (reg, payload bytes)."""

    def __init__(self, regs=None):
        self.regs = dict(regs or {})
        self.log = []
        self.reads = []
        self._nak = []

    def nak(self, n=1, errno=121):
        self._nak.extend([errno] * n)

    def poke(self, reg, data):
        """A foreign writer changes registers behind our back."""
        for i, b in enumerate(data):
            self.regs[reg + i] = b

    def __call__(self, msgs):
        if self._nak:
            err = self._nak.pop(0)
            raise OSError(err, 'Remote I/O error')
        out = []
        reg = None
        for flags, data in msgs:
            if flags & I2C_M_RD:
                self.reads.append((reg, data))
                out.append(bytes(self.regs.get(reg + i, 0)
                                 for i in range(data)))
            else:
                reg = (data[0] << 8) | data[1]
                if len(data) > 2:
                    self.log.append((reg, bytes(data[2:])))
                    self.poke(reg, data[2:])
        return out

    def writes(self):
        return [(hex(r), d.hex(' ')) for r, d in self.log]
