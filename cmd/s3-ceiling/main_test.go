package main

import (
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

func TestHeldBy95AndMedian(t *testing.T) {
	var v []float64
	for i := 1; i <= 20; i++ {
		v = append(v, float64(i))
	}
	// 19 of 20 windows (95%) reached 2.
	if got := heldBy95(v); got != 2 {
		t.Errorf("heldBy95 = %v, want 2", got)
	}
	if got := median(v); got != 10.5 {
		t.Errorf("median = %v, want 10.5", got)
	}
	if got := heldBy95([]float64{7}); got != 7 {
		t.Errorf("heldBy95 of one window = %v", got)
	}
}

func TestWindowRatesDropsPartialWindow(t *testing.T) {
	s := make([]float64, 100)
	for i := range s {
		s[i] = float64(i / 30) // 0 for 0-29, 1 for 30-59, ...
	}
	got := windowRates(s, 10, 100, 30)
	want := []float64{(20*0 + 10*1) / 30.0, (20*1 + 10*2) / 30.0, (20*2 + 10*3) / 30.0}
	if len(got) != len(want) {
		t.Fatalf("windows = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("window %d = %v, want %v", i, got[i], want[i])
		}
	}
}

func TestBurstEnd(t *testing.T) {
	var ena []enaSample
	// Flat for 20 minutes, a blip at 5 min, then rising every 10 s from 20 min.
	for s := 0; s <= 3600; s += 10 {
		var v int64
		switch {
		case s >= 1200:
			v = int64(s)
		case s >= 300:
			v = 1
		}
		ena = append(ena, enaSample{T: s, BwOut: v})
	}
	if _, ok := burstEnd(ena, 1400, 300); ok {
		t.Error("200 s of rising counter counted as the end of the burst")
	}
	got, ok := burstEnd(ena, 3600, 300)
	if !ok || got != 1190 {
		t.Errorf("burstEnd = %d, %v; want 1190, true", got, ok)
	}
	// One flat sample breaks the run.
	ena[130].BwOut = ena[129].BwOut
	if got, _ := burstEnd(ena, 3600, 300); got != 1300 {
		t.Errorf("burstEnd after a flat sample = %d, want 1300", got)
	}
}

func TestSteady(t *testing.T) {
	s := make([]float64, 1200)
	for i := range s {
		s[i] = 100
		if i >= 600 {
			s[i] = 104
		}
	}
	if !steady(s, 1200, 600, 0.05) {
		t.Error("4% apart counted as unsteady")
	}
	for i := 600; i < 1200; i++ {
		s[i] = 80
	}
	if steady(s, 1200, 600, 0.05) {
		t.Error("20% apart counted as steady")
	}
	if steady(s, 1000, 600, 0.05) {
		t.Error("too little data counted as steady")
	}
}

func TestFioSumsJobsPerSecond(t *testing.T) {
	dir := t.TempDir()
	var logs []string
	for job := 1; job <= 4; job++ {
		var b strings.Builder
		for s := 1; s <= 90; s++ {
			// fio's timestamps drift a few ms from the whole second.
			b.WriteString(strings.Join([]string{itoa(s*1000 + job), " 1024", " 1", " 1048576", " 0"}, ",") + "\n")
		}
		name := filepath.Join(dir, "nvme-pass1_bw."+itoa(job)+".log")
		if err := os.WriteFile(name, []byte(b.String()), 0o644); err != nil {
			t.Fatal(err)
		}
		logs = append(logs, name)
	}
	var out bytes.Buffer
	if err := fioCmd(append([]string{"-skip", "30s"}, logs...), &out); err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	// 4 jobs x 1024 KiB/s = 4 MiB/s; 60 s after the skip = 2 windows.
	if got["p5"] != float64(4<<20) || got["median"] != float64(4<<20) || got["windows"] != 2.0 || got["seconds"] != 90.0 {
		t.Errorf("fio summary = %v", got)
	}
	if err := fioCmd([]string{"-skip", "0s", writeTemp(t, "1000, x, 1\n")}, io.Discard); err == nil {
		t.Error("a malformed log line was accepted")
	}
}

func TestBodyIsNotSeekableAndCounts(t *testing.T) {
	var n atomic.Int64
	var r io.Reader = &body{buf: []byte("abc"), left: 10, count: &n}
	if _, ok := r.(io.Seeker); ok {
		t.Error("body implements io.Seeker")
	}
	if _, ok := r.(io.ReaderAt); ok {
		t.Error("body implements io.ReaderAt")
	}
	got, _ := io.ReadAll(r)
	if string(got) != "abcabcabca" || n.Load() != 10 {
		t.Errorf("read %q, counted %d", got, n.Load())
	}
}

func TestPhaseFlag(t *testing.T) {
	var p phases
	for _, bad := range []string{"64", "0:1m", "x:1m", "64:1ms", "64:"} {
		if p.Set(bad) == nil {
			t.Errorf("phase %q accepted", bad)
		}
	}
	if err := p.Set("64:75m"); err != nil || p[0].Workers != 64 || p[0].Dur != 75*time.Minute {
		t.Errorf("phase 64:75m = %+v, %v", p, err)
	}
}

// fakeS3 answers the calls PutObject and the cleanup make, on loopback only.
type fakeS3 struct {
	mu      sync.Mutex
	puts    map[string]int
	deletes map[string]int
	aborts  int
}

func (f *fakeS3) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	switch {
	case r.Method == http.MethodPut:
		n, _ := io.Copy(io.Discard, r.Body)
		if n == 0 {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		f.puts[r.URL.Path]++
		w.Header().Set("ETag", `"d41d8cd98f00b204e9800998ecf8427e"`)
	case r.Method == http.MethodDelete:
		f.deletes[r.URL.Path]++
		w.WriteHeader(http.StatusNoContent)
	case r.Method == http.MethodGet && r.URL.Query().Has("uploads"):
		f.aborts++
		w.Header().Set("Content-Type", "application/xml")
		io.WriteString(w, `<ListMultipartUploadsResult><Bucket>pdp</Bucket><IsTruncated>false</IsTruncated></ListMultipartUploadsResult>`)
	default:
		w.WriteHeader(http.StatusNotImplemented)
	}
}

func TestRunAgainstFakeS3(t *testing.T) {
	fake := &fakeS3{puts: map[string]int{}, deletes: map[string]int{}}
	srv := httptest.NewServer(fake)
	defer srv.Close()
	endpoint := strings.TrimPrefix(srv.URL, "http://")
	client, err := minio.New(endpoint, &minio.Options{Creds: credentials.NewStaticV4("k", "s", ""), Region: "us-east-2"})
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	stub := filepath.Join(dir, "ethtool")
	os.WriteFile(stub, []byte("#!/bin/sh\necho 'NIC statistics:'\necho '     bw_out_allowance_exceeded: 7'\necho '     pps_allowance_exceeded: 0'\n"), 0o755)
	c := putConfig{endpoint: endpoint, bucket: "pdp", prefix: "ceiling/test/", out: dir, iface: "ens5", ethtool: stub,
		objectBytes: 4096, enaEvery: time.Second}
	c.phases.Set("2:3s")
	c.phases.Set("4:2s")
	sum, err := run(context.Background(), client, c)
	if err != nil {
		t.Fatal(err)
	}
	if sum.Objects == 0 || sum.Errors != 0 || sum.MinioGo != "v7.3.0" || len(sum.Phases) != 2 {
		t.Errorf("summary = %+v", sum)
	}
	if sum.Phases[0].EndS != 3 || sum.Phases[1].StartS != 3 || sum.Phases[1].EndS != 5 {
		t.Errorf("phases = %+v", sum.Phases)
	}
	for key := range fake.puts {
		if !strings.HasPrefix(key, "/pdp/ceiling/test/w") {
			t.Errorf("PUT outside the prefix: %s", key)
		}
	}
	// Four workers ever ran, two keys each, all deleted and their uploads aborted.
	if len(fake.deletes) != 8 || fake.aborts != 8 {
		t.Errorf("cleanup deleted %d keys and listed uploads %d times, want 8 and 8", len(fake.deletes), fake.aborts)
	}

	rows := readCSV(t, filepath.Join(dir, "s3-put.csv"))
	if strings.Join(rows[0], ",") != "t,bytes,objects_done,errors,workers" || len(rows) != 6 {
		t.Fatalf("s3-put.csv = %v", rows)
	}
	var total, done int64
	for _, r := range rows[1:] {
		total += atoi(r[1])
		done += atoi(r[2])
	}
	if done == 0 || total < done*4096 || rows[1][4] != "2" || rows[5][4] != "4" {
		t.Errorf("s3-put.csv counted %d bytes for %d objects: %v", total, done, rows)
	}
	ena := readCSV(t, filepath.Join(dir, "ena.csv"))
	if len(ena) != 7 || ena[1][1] != "7" || ena[0][3] != "conntrack_allowance_exceeded" {
		t.Errorf("ena.csv = %v", ena)
	}
}

func TestPutRefusesWithoutKey(t *testing.T) {
	t.Setenv("FORGE_PERF_PIRI_S3_KEY_ID", "")
	if err := putCmd([]string{"-bucket", "b", "-phase", "1:1s"}); err == nil || !strings.Contains(err.Error(), "KEY_ID") {
		t.Errorf("put without a key: %v", err)
	}
	if err := putCmd([]string{"-bucket", "b", "-phase", "1:1s", "-burst-check", "60m"}); err == nil {
		t.Error("-burst-check without -burst-max accepted")
	}
}

func readCSV(t *testing.T, path string) [][]string {
	t.Helper()
	rows, err := csv.NewReader(bytes.NewReader(must(os.ReadFile(path)))).ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

func writeTemp(t *testing.T, s string) string {
	name := filepath.Join(t.TempDir(), "log")
	os.WriteFile(name, []byte(s), 0o644)
	return name
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func itoa(i int) string { return strconv.Itoa(i) }

func atoi(s string) int64 {
	n, _ := strconv.ParseInt(s, 10, 64)
	return n
}
