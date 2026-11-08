"""The clock blocks are timed against.

CLOCK_BOOTTIME keeps counting while the machine is suspended (closing the lid
still suspends unless the lid option is on) and, unlike wall time, never jumps
when NTP or the user changes the clock. A one-hour block that spent twenty
minutes suspended therefore has forty minutes left on resume, not sixty.
"""

import time


def now() -> float:
    return time.clock_gettime(time.CLOCK_BOOTTIME)
