# Make the tone for tools/audiotest.sh, or check what QEMU recorded.
#
# usage: audiocheck.py make file.wav
#        audiocheck.py check recorded.wav
#
# The tone is 2 seconds of 440 Hz, stereo, 16 bits, 44100 Hz, the format
# /dev/audio takes.  The check reads the samples after the header (QEMU
# may not have finished the header's sizes when it was stopped), finds
# the part that is not silent, and wants at least 1.5 seconds of it at
# 440 Hz, counted by zero crossings, in both channels.  It prints what
# it found either way.
import math, struct, sys, wave

RATE = 44100
FREQ = 440
SECS = 2


def make(path):
    w = wave.open(path, 'wb')
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(RATE)
    frames = bytearray()
    for i in range(RATE * SECS):
        v = int(16000 * math.sin(2 * math.pi * FREQ * i / RATE))
        frames += struct.pack('<hh', v, v)
    w.writeframes(bytes(frames))
    w.close()


def check(path):
    data = open(path, 'rb').read()
    if len(data) < 44 or data[:4] != b'RIFF':
        print('audio check: %s is not a wav file (%d bytes)' % (path, len(data)))
        return 1
    rate, = struct.unpack('<I', data[24:28])
    nch, = struct.unpack('<H', data[22:24])
    bits, = struct.unpack('<H', data[34:36])
    if nch != 2 or bits != 16:
        print('audio check: recorded %d channels of %d bits' % (nch, bits))
        return 1
    pcm = data[44:]
    n = len(pcm) // 4
    left = struct.unpack('<%dh' % (2 * n), pcm[:4 * n])
    loud = [i for i in range(n) if abs(left[2 * i]) > 1000]
    if not loud:
        print('audio check: %d frames at %d Hz, all silent' % (n, rate))
        return 1
    a, b = loud[0], loud[-1]
    secs = (b - a) / rate
    ok = True
    for ch, name in ((0, 'left'), (1, 'right')):
        s = left[2 * a + ch:2 * b:2]
        zc = sum(1 for i in range(1, len(s)) if (s[i - 1] < 0) != (s[i] < 0))
        hz = zc / 2 / secs if secs > 0 else 0
        print('audio check: %s: %.2f s of sound at %.1f Hz (%d frames at %d Hz in all)' % (name, secs, hz, n, rate))
        if abs(hz - FREQ) > 5:
            ok = False
    if secs < 1.5:
        ok = False
    print('audio check: ' + ('ok' if ok else 'failed'))
    return 0 if ok else 1


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'make':
        make(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == 'check':
        sys.exit(check(sys.argv[2]))
    else:
        print('usage: audiocheck.py make|check file.wav', file=sys.stderr)
        sys.exit(2)
