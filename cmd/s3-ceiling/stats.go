package main

import (
	"bufio"
	"fmt"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
)

// Rates are bytes per second. A per-second series is indexed by second.

// Stat is a series scored the way the drill scores its ingest rate: 30-second
// windows, their p5 (the highest rate at least 95% of windows held) and their
// median.
type Stat struct {
	P5      float64 `json:"p5"`
	Median  float64 `json:"median"`
	Windows int     `json:"windows"`
}

// windowRates splits perSecond[from:to] into whole windows of size seconds
// and returns each window's mean rate. A partial last window is dropped.
func windowRates(perSecond []float64, from, to, size int) []float64 {
	from = max(from, 0)
	to = min(to, len(perSecond))
	var out []float64
	for start := from; start+size <= to; start += size {
		sum := 0.0
		for _, v := range perSecond[start : start+size] {
			sum += v
		}
		out = append(out, sum/float64(size))
	}
	return out
}

func score(windows []float64) Stat {
	return Stat{P5: heldBy95(windows), Median: median(windows), Windows: len(windows)}
}

// median and heldBy95 follow storage-qualification's internal/evidence
// (sustained.go), so a ceiling and a drill result are the same statistic.
func median(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[mid]
	}
	return (sorted[mid-1] + sorted[mid]) / 2
}

func heldBy95(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	held := 0
	for float64(held) < 0.95*float64(len(sorted)) {
		held++
	}
	return sorted[len(sorted)-held]
}

func mean(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sum := 0.0
	for _, v := range values {
		sum += v
	}
	return sum / float64(len(values))
}

// enaSample is one reading of the ENA allowance counters, t seconds in.
type enaSample struct {
	T         int
	BwOut     int64
	Pps       int64
	Conntrack int64
}

// burstEnd returns the second at which the burst allowance ran out: the start
// of the first run of samples, rising in every sample for at least streak
// seconds, of bw_out_allowance_exceeded. False when no such run exists up to
// second at.
func burstEnd(ena []enaSample, at, streak int) (int, bool) {
	runStart := -1
	for i := 1; i < len(ena) && ena[i].T <= at; i++ {
		if ena[i].BwOut > ena[i-1].BwOut {
			if runStart < 0 {
				runStart = ena[i-1].T
			}
			if ena[i].T-runStart >= streak {
				return runStart, true
			}
		} else {
			runStart = -1
		}
	}
	return 0, false
}

// steady reports whether the mean rate of the span seconds before at is
// within tolerance of the span before that.
func steady(perSecond []float64, at, span int, tolerance float64) bool {
	if at-2*span < 0 || at > len(perSecond) {
		return false
	}
	last := mean(perSecond[at-span : at])
	before := mean(perSecond[at-2*span : at-span])
	return before > 0 && math.Abs(last-before) <= tolerance*before
}

// fioSeconds reads fio bandwidth logs (--write_bw_log with --log_avg_msec=1000:
// "msec, KiB/s, direction, block size, offset[, priority]" per line) and sums
// every log's rate per second, since fio writes one log per job.
func fioSeconds(logs []io.Reader) ([]float64, error) {
	var perSecond []float64
	for _, r := range logs {
		s := bufio.NewScanner(r)
		for s.Scan() {
			f := strings.Split(s.Text(), ",")
			if len(f) < 2 {
				continue
			}
			ms, err1 := strconv.ParseFloat(strings.TrimSpace(f[0]), 64)
			kib, err2 := strconv.ParseFloat(strings.TrimSpace(f[1]), 64)
			if err1 != nil || err2 != nil {
				return nil, fmt.Errorf("fio log line %q is not msec, KiB/s", s.Text())
			}
			sec := int(math.Round(ms/1000)) - 1
			if sec < 0 {
				sec = 0
			}
			for len(perSecond) <= sec {
				perSecond = append(perSecond, 0)
			}
			perSecond[sec] += kib * 1024
		}
		if err := s.Err(); err != nil {
			return nil, err
		}
	}
	return perSecond, nil
}
