#!/usr/bin/env python

import sys
from struct import pack, unpack, calcsize
import base64
import time
from datetime import timedelta

def flipend(end):
    if end == '<':
        return '>'
    if end == '>':
        return '<'

def printGenState(dn, nsstate, flip):
    if pack('<h', 1) == pack('=h',1):
        print "Little Endian"
        end = '<'
        if flip:
            end = flipend(end)
    elif pack('>h', 1) == pack('=h',1):
        print "Big Endian"
        end = '>'
        if flip:
            end = flipend(end)
    else:
        print "Unknown Endian"
        sys.exit(-1) # blow up
    print "For replica", dn
    thelen = len(nsstate)
    if thelen <= 20:
        pad = 2 # padding for short H values
        timefmt = 'I' # timevals are unsigned 32-bit int
    else:
        pad = 6 # padding for short H values
        timefmt = 'Q' # timevals are unsigned 64-bit int

    base_fmtstr = "H%dx3%sH%dx" % (pad, timefmt, pad)
    print "  fmtstr=[%s]" % base_fmtstr
    print "  size=%d" % calcsize(base_fmtstr)
    print "  len of nsstate is", thelen
    fmtstr = end + base_fmtstr
    (rid, sampled_time, local_offset, remote_offset, seq_num) = unpack(fmtstr, nsstate)
    now = int(time.time())
    tdiff = now-sampled_time
    wrongendian = False
    try:
        tdelta = timedelta(seconds=tdiff)
        wrongendian = tdelta.days > 10*365
    except OverflowError: # int overflow
        wrongendian = True
    # if the sampled time is more than 20 years off, this is
    # probably the wrong endianness
    if wrongendian:
        print "The difference in days is", tdiff/86400
        print "This is probably the wrong bit-endianness - flipping"
        end = flipend(end)
        fmtstr = end + base_fmtstr
        (rid, sampled_time, local_offset, remote_offset, seq_num) = unpack(fmtstr, nsstate)
        tdiff = now-sampled_time
        tdelta = timedelta(seconds=tdiff)
    print """  CSN generator state:
    Replica ID    : %d
    Sampled Time  : %d
    Gen as csn    : %08x%04d%04d0000
    Time as str   : %s
    Local Offset  : %d
    Remote Offset : %d
    Seq. num      : %d
    System time   : %s
    Diff in sec.  : %d
    Day:sec diff  : %d:%d
""" % (rid, sampled_time, sampled_time, seq_num, rid, time.ctime(sampled_time), local_offset,
       remote_offset, seq_num, time.ctime(now), tdiff, tdelta.days, tdelta.seconds)

def main():
    dn = ''
    nsstate = ''
    if len(sys.argv) > 2:
        flip = True
    else:
        flip = False
    for line in open(sys.argv[1]):
        if line.startswith("dn: "):
            dn = line[4:].strip()
        if line.startswith("nsState:: ") and dn.startswith("cn=replica"):
            b64val = line[10:].strip()
            print "nsState is", b64val
            nsstate = base64.decodestring(b64val)
            printGenState(dn, nsstate, flip)
    if not nsstate:
        print "Error: nsstate not found in file", sys.argv[1]
        sys.exit(1)

if __name__ == '__main__':
    main()
