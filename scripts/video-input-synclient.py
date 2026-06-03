#!/usr/bin/env python3
# Synthetic PATH-2 client over real UDP loopback. Drives the host's INPUT path directly
# (the root-cause location), so the ordering/balance fix can be verified deterministically
# without the GUI client or computer-use cursor war.
#
#   synclient.py click   X Y            # one down+up at normalized (X,Y)
#   synclient.py clickburst N           # N rapid clicks down/up back-to-back (provoke reorder)
#   synclient.py drag X1 Y1 X2 Y2 STEPS # down, STEPS drags, up  (drag-select)
#   synclient.py hello                  # just hello + print ack, hold 2s
import socket, struct, sys, time

HOST = "127.0.0.1"; MEDIA = 9000; CURSOR = 9001; WID = 267; VERSION = 1
CH_CONTROL = 0x00; CH_INPUT = 0x04
LEFT = 0

def media_sock():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((HOST, MEDIA)); s.settimeout(2.0); return s

def hello(s):
    body = struct.pack(">B", 0x01) + struct.pack(">H", VERSION) + struct.pack(">I", WID) \
         + struct.pack(">d", 656.0) + struct.pack(">d", 433.0)
    s.send(bytes([CH_CONTROL]) + body)

def read_ack(s):
    try:
        data = s.recv(2048)
    except socket.timeout:
        return None
    # media datagrams are [1-byte channel tag][payload]; control = 0x00
    if len(data) < 2 or data[0] != CH_CONTROL: return ("non-control", data)
    p = data[1:]
    if p[0] != 0x02: return ("not-ack", p)
    accepted = p[1]; (streamID,) = struct.unpack(">I", p[2:6])
    (cw,) = struct.unpack(">H", p[6:8]); (ch,) = struct.unpack(">H", p[8:10])
    bx, by, bw, bh = struct.unpack(">dddd", p[10:42])
    return dict(accepted=accepted, streamID=streamID, cw=cw, ch=ch, bounds=(bx, by, bw, bh))

TAG = [100]
def tag():
    TAG[0] += 1; return TAG[0]

def button_evt(s, etype, x, y, clicks=1):
    # type: 2=down 3=up 7=drag ; payload: tag(u32) button(u8) clicks(u8) mods(u8) x(f64) y(f64)
    body = struct.pack(">B", etype) + struct.pack(">I", tag()) + bytes([LEFT, clicks, 0]) \
         + struct.pack(">d", x) + struct.pack(">d", y)
    s.send(bytes([CH_INPUT]) + body)

def down(s, x, y, c=1): button_evt(s, 2, x, y, c)
def up(s, x, y, c=1):   button_evt(s, 3, x, y, c)
def drag(s, x, y, c=1): button_evt(s, 7, x, y, c)

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "hello"
    s = media_sock()
    # cursor prime (mirror the real client; harmless)
    cs = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); cs.connect((HOST, CURSOR)); cs.send(b"\x00")
    hello(s)
    ack = read_ack(s)
    print("ACK:", ack)
    if not isinstance(ack, dict) or not ack.get("accepted"):
        print("!! hello not accepted"); return
    time.sleep(0.2)

    if cmd == "suite":
        # One connection, one source port (host stays pinned to us). Exercises the
        # down/up-inversion race (rapid clicks) then a drag-select, all in arrival order.
        print(">> 15 rapid clicks (caret moves; must NOT leave a selection)")
        for i in range(15):
            x = 0.10 + 0.035 * i; y = 0.20
            down(s, x, y); up(s, x, y)
            time.sleep(0.04)
        time.sleep(0.6)
        print(">> drag-select across line 2")
        x1, y1, x2, y2 = 0.05, 0.40, 0.75, 0.40
        down(s, x1, y1)
        for i in range(1, 15):
            t = i / 15.0
            drag(s, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t); time.sleep(0.012)
        up(s, x2, y2)
        time.sleep(0.6)
    elif cmd == "redundantup":
        # Mimic the real client: a click whose mouseUp is sent 3x (loss-resilience). The host
        # must post ONE leftMouseUp and SUPPRESS the other two (no spurious extra *MouseUp).
        print(">> click with 3x redundant mouseUp")
        down(s, 0.3, 0.21)
        up(s, 0.3, 0.21); up(s, 0.3, 0.21); up(s, 0.3, 0.21)
        time.sleep(0.4)
    elif cmd == "lostup":
        # Simulate a DROPPED mouseUp: down + drags, NO up. Then a fresh click elsewhere.
        # In fixed mode the host's button-balance must inject a synthetic release before the
        # fresh down (so the click does not start inside the stranded selection).
        print(">> down + 6 drags, NO up (simulates a lost release)")
        down(s, 0.05, 0.21)
        for i in range(1, 7):
            drag(s, 0.05 + 0.06 * i, 0.21); time.sleep(0.02)
        time.sleep(0.5)
        print(">> fresh click far away (must auto-release the stuck button first)")
        down(s, 0.8, 0.6); up(s, 0.8, 0.6)
        time.sleep(0.5)
    elif cmd == "hello":
        time.sleep(2.0)
    elif cmd == "click":
        x, y = float(sys.argv[2]), float(sys.argv[3])
        down(s, x, y); up(s, x, y)
        print(f"click at ({x},{y})")
    elif cmd == "clickburst":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 10
        for i in range(n):
            x = 0.2 + 0.03 * i; y = 0.2
            down(s, x, y); up(s, x, y)   # back-to-back: provoke host reorder
            time.sleep(0.05)
        print(f"{n} rapid clicks sent")
    elif cmd == "drag":
        x1, y1, x2, y2 = map(float, sys.argv[2:6])
        steps = int(sys.argv[6]) if len(sys.argv) > 6 else 12
        down(s, x1, y1)
        for i in range(1, steps + 1):
            t = i / steps
            drag(s, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
            time.sleep(0.012)
        up(s, x2, y2)
        print(f"drag ({x1},{y1})->({x2},{y2}) in {steps} steps")
    time.sleep(0.4)
    s.close(); cs.close()

main()
