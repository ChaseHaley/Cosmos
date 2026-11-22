package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "cosmos:host"

// What the probe learned about a video: its size in bytes, as a clipper would read its streams.
Probe_Result :: struct {
	path: string,
	size: i64,
	ok:   bool,
}

// Reads the chosen videos on a worker thread, so a slow disk never stalls a frame, and hands each result
// back through an inbox, which wakes the loop.
Probe :: struct {
	thread:  ^thread.Thread,
	// Guards jobs and stop.
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	jobs:    [dynamic]string,
	stop:    bool,
	results: host.Inbox(Probe_Result),
}

@(require_results)
probe_start :: proc(p: ^Probe, waker: host.Waker) -> bool {
	host.inbox_init(&p.results, waker)
	p.thread = thread.create(probe_run)
	if p.thread == nil {return false}
	p.thread.data = p
	p.thread.init_context = context
	thread.start(p.thread)
	return true
}

// Queues `path` for the worker, which copies it.
probe_post :: proc(p: ^Probe, path: string) {
	copied := strings.clone(path)
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)
	append(&p.jobs, copied)
	sync.cond_signal(&p.cond)
}

// Stops the worker once its current job is done and frees what nobody took.
probe_stop :: proc(p: ^Probe) {
	if p.thread != nil {
		sync.mutex_lock(&p.mutex)
		p.stop = true
		sync.cond_signal(&p.cond)
		sync.mutex_unlock(&p.mutex)
		thread.join(p.thread)
		thread.destroy(p.thread)
	}
	for path in p.jobs {delete(path)}
	delete(p.jobs)
	host.inbox_destroy(&p.results, probe_result_destroy)
}

probe_result_destroy :: proc(result: ^Probe_Result) {
	delete(result.path)
}

@(private = "file")
probe_run :: proc(t: ^thread.Thread) {
	p := (^Probe)(t.data)
	for {
		sync.mutex_lock(&p.mutex)
		for len(p.jobs) == 0 && !p.stop {sync.cond_wait(&p.cond, &p.mutex)}
		if p.stop {
			sync.mutex_unlock(&p.mutex)
			return
		}
		path := pop_front(&p.jobs)
		sync.mutex_unlock(&p.mutex)
		result := Probe_Result {
			path = path,
		}
		if info, err := os.stat(path, context.temp_allocator); err == nil {result.size, result.ok = info.size, true}
		free_all(context.temp_allocator)
		if host.inbox_push(&p.results, result) != nil {probe_result_destroy(&result)}
	}
}
