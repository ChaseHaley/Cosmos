package host

import "base:runtime"
// Only the polymorphic procs use sync, and they are checked where they are instantiated.
@(require) import "core:sync"

// Results a worker hands to the UI thread: a push appends under the lock and wakes the loop, and the UI
// thread takes everything queued at once. The inbox owns nothing inside its items; whoever takes an
// item owns it, and inbox_destroy hands the untaken ones to `release`.
Inbox :: struct($T: typeid) {
	mutex: sync.Mutex,
	items: [dynamic]T,
	waker: Waker,
}

inbox_init :: proc(b: ^Inbox($T), waker: Waker, allocator := context.allocator) {
	b.items = make([dynamic]T, allocator)
	b.waker = waker
}

// Frees the inbox, passing each item nobody took to `release` first.
inbox_destroy :: proc(b: ^Inbox($T), release: proc(item: ^T) = nil) {
	if release != nil {
		for &item in b.items {release(&item)}
	}
	delete(b.items)
	b.items = nil
}

// Queues `items` and wakes the loop; on failure nothing is queued and the caller still owns them.
@(require_results)
inbox_push :: proc(b: ^Inbox($T), items: ..T) -> runtime.Allocator_Error {
	if len(items) == 0 {return nil}
	sync.mutex_lock(&b.mutex)
	_, err := append(&b.items, ..items)
	sync.mutex_unlock(&b.mutex)
	if err == nil {wake(b.waker)}
	return err
}

// Moves every queued item to the end of `out`; on failure they stay queued.
@(require_results)
inbox_take :: proc(b: ^Inbox($T), out: ^[dynamic]T) -> runtime.Allocator_Error {
	sync.mutex_lock(&b.mutex)
	defer sync.mutex_unlock(&b.mutex)
	if len(b.items) == 0 {return nil}
	append(out, ..b.items[:]) or_return
	clear(&b.items)
	return nil
}

// Whether anything is queued.
inbox_pending :: proc(b: ^Inbox($T)) -> bool {
	sync.mutex_lock(&b.mutex)
	defer sync.mutex_unlock(&b.mutex)
	return len(b.items) > 0
}
