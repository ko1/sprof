# sprof Complete Guide

## A Safepoint-Bias-Correcting Sampling Profiler for Ruby

sprof is a sampling profiler for Ruby that uses actual time deltas as sample weights to correct safepoint bias. It produces output in the industry-standard pprof protobuf format, viewable with `go tool pprof`.

This guide covers sprof's motivation, architecture, usage, and how it compares to other Ruby profilers. Whether you need to track down CPU hotspots, diagnose GVL contention, or understand GC overhead, sprof provides accurate, low-overhead profiling for production Ruby applications.

**Requirements:** Ruby >= 4.0.0, Linux only.
