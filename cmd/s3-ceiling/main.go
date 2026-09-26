// Command s3-ceiling measures an instance's sustained S3 PUT throughput
// through the client call piri makes: minio-go's PutObject of a fixed-size,
// non-seekable body with default options (piri/pkg/store/objectstore/minio,
// Store.Put). go.mod pins minio-go to piri's version, and CI fails when the
// two differ. docs/DESIGN.md §9 and calibration/README.md describe the method.
//
//	s3-ceiling put -bucket B -prefix P -out DIR -phase 64:75m [-phase 128:10m ...]
//	    [-score-last 30m | -score-drop 5m] [-burst-check 60m -burst-max 120m]
//	    [-endpoint host] [-region r] [-insecure] [-iface ens5]
//	s3-ceiling fio [-skip 30s] LOG...
//
// put runs the phases back to back with no pause and writes s3-put.csv (one row
// per second), ena.csv (the ENA allowance counters every 10 s) and s3-put.json
// (the first phase scored as p5 and median of 30 s windows) to DIR. It takes
// piri's key from FORGE_PERF_PIRI_S3_KEY_ID and FORGE_PERF_PIRI_S3_SECRET, and
// deletes its keys and aborts its uploads when it ends.
//
// fio scores fio bandwidth logs the same way and prints the result as JSON.
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

const window = 30

type phase struct {
	Workers int           `json:"workers"`
	Dur     time.Duration `json:"-"`
	StartS  int           `json:"start_s"`
	EndS    int           `json:"end_s"`
	Median  float64       `json:"median"`
}

type phases []phase

func (p *phases) String() string { return fmt.Sprint(*p) }
func (p *phases) Set(v string) error {
	w, d, ok := strings.Cut(v, ":")
	n, err := strconv.Atoi(w)
	if !ok || err != nil || n < 1 {
		return fmt.Errorf("phase %q is not <workers>:<duration>", v)
	}
	dur, err := time.ParseDuration(d)
	if err != nil || dur < time.Second {
		return fmt.Errorf("phase %q has no duration of a second or more", v)
	}
	*p = append(*p, phase{Workers: n, Dur: dur})
	return nil
}

type putConfig struct {
	endpoint, region, bucket, prefix, out, iface, ethtool string
	insecure                                              bool
	objectBytes                                           int64
	phases                                                phases
	scoreLast, scoreDrop, burstCheck, burstMax, enaEvery  time.Duration
}

// Summary is s3-put.json.
type Summary struct {
	Stat
	Workers         int      `json:"workers"`
	ObjectBytes     int64    `json:"object_bytes"`
	SustainedFromS  int      `json:"sustained_from_s"`
	BurstEndedS     *int     `json:"burst_ended_s"`
	Phases          []phase  `json:"phases"`
	Objects         int64    `json:"objects"`
	Errors          int64    `json:"errors"`
	Flags           []string `json:"flags"`
	MinioGo         string   `json:"minio_go"`
	Endpoint        string   `json:"endpoint"`
	Bucket          string   `json:"bucket"`
	ThroughputUnits string   `json:"units"`
}

func main() {
	log.SetFlags(0)
	log.SetPrefix("s3-ceiling: ")
	if len(os.Args) < 2 {
		log.Fatal("usage: s3-ceiling put|fio ...")
	}
	var err error
	switch os.Args[1] {
	case "put":
		err = putCmd(os.Args[2:])
	case "fio":
		err = fioCmd(os.Args[2:], os.Stdout)
	default:
		err = fmt.Errorf("unknown command %q; want put or fio", os.Args[1])
	}
	if err != nil {
		log.Fatal(err)
	}
}

func fioCmd(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("fio", flag.ContinueOnError)
	skip := fs.Duration("skip", 30*time.Second, "seconds dropped from the start")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() == 0 {
		return errors.New("fio: name at least one bandwidth log")
	}
	var readers []io.Reader
	for _, name := range fs.Args() {
		f, err := os.Open(name)
		if err != nil {
			return err
		}
		defer f.Close()
		readers = append(readers, f)
	}
	perSecond, err := fioSeconds(readers)
	if err != nil {
		return err
	}
	st := score(windowRates(perSecond, int(skip.Seconds()), len(perSecond), window))
	return json.NewEncoder(stdout).Encode(map[string]any{
		"p5": st.P5, "median": st.Median, "windows": st.Windows, "seconds": len(perSecond), "units": "bytes/s",
	})
}

func putCmd(args []string) error {
	var c putConfig
	fs := flag.NewFlagSet("put", flag.ContinueOnError)
	fs.StringVar(&c.endpoint, "endpoint", "s3.us-east-2.amazonaws.com", "host[:port], as piri's storage.s3.endpoint")
	fs.StringVar(&c.region, "region", "", "empty takes the region from the endpoint, as piri does")
	fs.BoolVar(&c.insecure, "insecure", false, "plain HTTP")
	fs.StringVar(&c.bucket, "bucket", "", "bucket (the box's pdp bucket)")
	fs.StringVar(&c.prefix, "prefix", "ceiling/", "key prefix")
	fs.StringVar(&c.out, "out", ".", "output directory")
	fs.StringVar(&c.iface, "iface", "", "NIC whose ENA counters are sampled; empty samples none")
	fs.StringVar(&c.ethtool, "ethtool", "ethtool", "ethtool binary")
	fs.Int64Var(&c.objectBytes, "object-bytes", 134217728, "bytes per PUT")
	fs.Var(&c.phases, "phase", "<workers>:<duration>, repeated; the first is scored")
	fs.DurationVar(&c.scoreLast, "score-last", 0, "score the last this much of the first phase")
	fs.DurationVar(&c.scoreDrop, "score-drop", 0, "or score the first phase after dropping this much")
	fs.DurationVar(&c.burstCheck, "burst-check", 0, "when into the first phase the burst must have ended")
	fs.DurationVar(&c.burstMax, "burst-max", 0, "what the first phase extends to when it has not")
	fs.DurationVar(&c.enaEvery, "ena-every", 10*time.Second, "ENA sampling interval")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if c.bucket == "" || len(c.phases) == 0 {
		return errors.New("put needs -bucket and at least one -phase")
	}
	if (c.burstCheck > 0) != (c.burstMax > c.burstCheck) {
		return errors.New("-burst-check needs a longer -burst-max")
	}
	id, secret := os.Getenv("FORGE_PERF_PIRI_S3_KEY_ID"), os.Getenv("FORGE_PERF_PIRI_S3_SECRET")
	if id == "" || secret == "" {
		return errors.New("FORGE_PERF_PIRI_S3_KEY_ID and FORGE_PERF_PIRI_S3_SECRET must be set")
	}
	// piri's options (piri/pkg/fx/store/s3/provider.go): static key, Secure
	// unless insecure, no region.
	client, err := minio.New(c.endpoint, &minio.Options{
		Creds: credentials.NewStaticV4(id, secret, ""), Secure: !c.insecure, Region: c.region,
	})
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	sum, err := run(ctx, client, c)
	if err != nil {
		return err
	}
	f, err := os.Create(filepath.Join(c.out, "s3-put.json"))
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	return enc.Encode(sum)
}

// body yields size bytes cycled from buf and hides io.Seeker and io.ReaderAt,
// as piri's HTTP request body does, counting each byte minio-go reads.
type body struct {
	buf   []byte
	off   int
	left  int64
	count *atomic.Int64
}

func (b *body) Read(p []byte) (int, error) {
	if b.left == 0 {
		return 0, io.EOF
	}
	if int64(len(p)) > b.left {
		p = p[:b.left]
	}
	n := copy(p, b.buf[b.off:])
	b.off = (b.off + n) % len(b.buf)
	b.left -= int64(n)
	b.count.Add(int64(n))
	return n, nil
}

func run(ctx context.Context, client *minio.Client, c putConfig) (*Summary, error) {
	buf := make([]byte, min(c.objectBytes, 64<<20))
	if _, err := rand.Read(buf); err != nil {
		return nil, err
	}
	csvF, err := os.Create(filepath.Join(c.out, "s3-put.csv"))
	if err != nil {
		return nil, err
	}
	defer csvF.Close()
	csvW := bufio.NewWriter(csvF)
	defer csvW.Flush()
	fmt.Fprintln(csvW, "t,bytes,objects_done,errors,workers")

	var bytes, objects, failures atomic.Int64
	var target atomic.Int32
	maxWorkers := 0
	for _, p := range c.phases {
		maxWorkers = max(maxWorkers, p.Workers)
	}
	work, stopWork := context.WithCancel(ctx)
	defer stopWork()
	var wg sync.WaitGroup
	for w := range maxWorkers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; work.Err() == nil; {
				if int(target.Load()) <= w {
					time.Sleep(50 * time.Millisecond)
					continue
				}
				key := fmt.Sprintf("%sw%d/%d", c.prefix, w, n%2)
				r := &body{buf: buf, left: c.objectBytes, count: &bytes}
				if _, err := client.PutObject(work, c.bucket, key, r, c.objectBytes, minio.PutObjectOptions{}); err != nil {
					if work.Err() == nil {
						failures.Add(1)
						log.Printf("worker %d: %v", w, err)
						time.Sleep(time.Second)
					}
					continue
				}
				objects.Add(1)
				n++
			}
		}()
	}

	var perSecond []float64
	var ena []enaSample
	ena = c.sampleENA(ena, 0)
	start := time.Now()
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	var lastBytes, lastObjects, lastFailures int64
	sum := &Summary{ObjectBytes: c.objectBytes, Workers: c.phases[0].Workers, Flags: []string{},
		MinioGo: minioVersion(), Endpoint: c.endpoint, Bucket: c.bucket, ThroughputUnits: "bytes/s"}
	enaEvery := max(int(c.enaEvery.Seconds()), 1)

phases:
	for i := range c.phases {
		p := &c.phases[i]
		p.StartS = len(perSecond)
		end := p.StartS + int(p.Dur.Seconds())
		target.Store(int32(p.Workers))
		log.Printf("phase %d: %d workers for %s", i+1, p.Workers, p.Dur)
		for len(perSecond) < end {
			select {
			case <-ctx.Done():
				p.EndS = len(perSecond)
				sum.Flags = append(sum.Flags, "interrupted")
				c.phases = c.phases[:i+1]
				break phases
			case <-tick.C:
			}
			b, o, e := bytes.Load(), objects.Load(), failures.Load()
			perSecond = append(perSecond, float64(b-lastBytes))
			t := len(perSecond)
			fmt.Fprintf(csvW, "%d,%d,%d,%d,%d\n", t, b-lastBytes, o-lastObjects, e-lastFailures, p.Workers)
			lastBytes, lastObjects, lastFailures = b, o, e
			if c.iface != "" && t%enaEvery == 0 {
				ena = c.sampleENA(ena, t)
			}
			// The first phase runs until the burst has visibly ended: the
			// allowance counter rising for 5 minutes and the rate steady.
			if i == 0 && c.burstCheck > 0 && t-p.StartS == int(c.burstCheck.Seconds()) {
				_, ended := burstEnd(ena, t, 300)
				if !ended || !steady(perSecond, t, 600, 0.05) {
					end = p.StartS + int(c.burstMax.Seconds())
					sum.Flags = append(sum.Flags, "burst_unconfirmed")
					log.Printf("the burst has not visibly ended at %s; the phase runs to %s", c.burstCheck, c.burstMax)
				}
			}
		}
		p.EndS = len(perSecond)
	}
	stopWork()
	wg.Wait()
	log.Printf("%.0f s elapsed; removing %s", time.Since(start).Seconds(), c.prefix)
	cleanup(client, c.bucket, c.prefix, maxWorkers)
	if err := writeENA(filepath.Join(c.out, "ena.csv"), ena); err != nil {
		return nil, err
	}

	first := c.phases[0]
	from := first.StartS + int(c.scoreDrop.Seconds())
	if c.scoreLast > 0 {
		from = max(first.StartS, first.EndS-int(c.scoreLast.Seconds()))
	}
	sum.SustainedFromS = from
	sum.Stat = score(windowRates(perSecond, from, first.EndS, window))
	if s, ok := burstEnd(ena, first.EndS, 300); ok {
		sum.BurstEndedS = &s
	}
	for i := range c.phases {
		p := &c.phases[i]
		// A phase's first 30 s carry the change of worker count.
		p.Median = median(windowRates(perSecond, min(p.StartS+window, p.EndS), p.EndS, window))
		if i > 0 && p.Workers > first.Workers && p.Median > 1.03*sum.Median {
			sum.Flags = append(sum.Flags, "under_driven")
		}
	}
	sum.Phases = c.phases
	sum.Objects, sum.Errors = objects.Load(), failures.Load()
	return sum, nil
}

// cleanup deletes every key the workers could have written and aborts their
// incomplete multipart uploads. A failure is logged: the box's wipe empties
// the bucket before the next run anyway.
func cleanup(client *minio.Client, bucket, prefix string, workers int) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	for w := range workers {
		for n := range 2 {
			key := fmt.Sprintf("%sw%d/%d", prefix, w, n)
			if err := client.RemoveIncompleteUpload(ctx, bucket, key); err != nil {
				log.Printf("abort uploads of %s: %v", key, err)
			}
			if err := client.RemoveObject(ctx, bucket, key, minio.RemoveObjectOptions{}); err != nil {
				log.Printf("delete %s: %v", key, err)
			}
		}
	}
}

// sampleENA appends one reading of `ethtool -S <iface>`. A failed read is
// logged and skipped.
func (c putConfig) sampleENA(ena []enaSample, t int) []enaSample {
	if c.iface == "" {
		return ena
	}
	out, err := exec.Command(c.ethtool, "-S", c.iface).Output()
	if err != nil {
		log.Printf("ethtool -S %s: %v", c.iface, err)
		return ena
	}
	s := enaSample{T: t}
	for _, line := range strings.Split(string(out), "\n") {
		name, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		v, err := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
		if !ok || err != nil {
			continue
		}
		switch name {
		case "bw_out_allowance_exceeded":
			s.BwOut = v
		case "pps_allowance_exceeded":
			s.Pps = v
		case "conntrack_allowance_exceeded":
			s.Conntrack = v
		}
	}
	return append(ena, s)
}

func writeENA(path string, ena []enaSample) error {
	var b strings.Builder
	b.WriteString("t,bw_out_allowance_exceeded,pps_allowance_exceeded,conntrack_allowance_exceeded\n")
	for _, s := range ena {
		fmt.Fprintf(&b, "%d,%d,%d,%d\n", s.T, s.BwOut, s.Pps, s.Conntrack)
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

func minioVersion() string {
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, d := range info.Deps {
			if d.Path == "github.com/minio/minio-go/v7" {
				return d.Version
			}
		}
	}
	return "unknown"
}
