# lastval.awk -v map=<BAR0 map id> -v stop=<text of the MARK to stop at> [-v lo=0x137000 -v hi=0x137400]
# Prints the last value read or written for each register in [lo, hi) before that MARK.
BEGIN { lo = lo ? strtonum(lo) : 0x137000; hi = hi ? strtonum(hi) : 0x137400 }
$1 == "MARK" && index($0, stop) { exit }
($1 == "R" || $1 == "W") && $4 == map {
	off = strtonum($5) - 0xd0000000
	if (off >= lo && off < hi) v[sprintf("%06x", off)] = sprintf("%08x", strtonum($6))
}
END { for (k in v) print k, v[k] }
