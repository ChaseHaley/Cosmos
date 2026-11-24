package platform

@(require) import "cosmos:input"
@(require) import "core:log"
@(require) import w "core:sys/windows"

// UI Automation for a window: native/windows_uia.cpp keeps a copy of the tree the app last set and serves
// it to screen readers. They reach it through WM_GETOBJECT; what they ask of a node comes back through
// access_request, on the UI thread, as an event in the queue.
when !HEADLESS {
	foreign import uia_native {
		"../../build/native/uia.lib",
		"system:uiautomationcore.lib",
		"system:oleaut32.lib",
	}

	// The C++ side reads an Access_Node slice as is.
	#assert(size_of(Access_Node) == 80)
	#assert(offset_of(Access_Node, role) == 16)
	#assert(offset_of(Access_Node, name) == 24)
	#assert(offset_of(Access_Node, value) == 40)
	#assert(offset_of(Access_Node, bounds) == 56)
	#assert(offset_of(Access_Node, states) == 72)

	// The lParam of WM_GETOBJECT that asks for a UI Automation provider.
	@(private)
	UIA_ROOT_OBJECT_ID :: -25

	// What an assistive technology asked of a node, in the order of Request in native/windows_uia.cpp.
	@(private)
	Access_Request :: enum i32 {
		Invoke,
		Toggle,
		Expand,
		Collapse,
		Focus,
	}

	@(private)
	Access_Request_Proc :: proc "c" (user: rawptr, id: Access_Id, request: Access_Request)

	@(private, default_calling_convention = "c")
	foreign uia_native {
		cosmos_uia_create :: proc(
			window: w.HWND,
			user: rawptr,
			request: Access_Request_Proc,
			out: ^rawptr,
		) -> i32 ---
		cosmos_uia_answer :: proc(state: rawptr, wp: w.WPARAM, lp: w.LPARAM) -> w.LRESULT ---
		cosmos_uia_set :: proc(state: rawptr, nodes: [^]Access_Node, count: uint, focus: Access_Id) -> i32 ---
		cosmos_uia_destroy :: proc(state: rawptr) -> i32 ---
	}

	@(private, default_calling_convention = "system")
	foreign uia_native {
		UiaDisconnectAllProviders :: proc() -> i32 ---
	}

	// Replaces the window's accessibility tree with a copy of `nodes`, which are borrowed for the call, and
	// names the node with keyboard focus, or 0. A tree equal to the one held costs only the comparison.
	// Invalid_Argument means an id is 0 or repeated, a parent is not an earlier node, or `focus` is not a
	// node; the tree held is then kept.
	@(require_results)
	window_access_set :: proc(
		p: ^Platform,
		window: input.Window_Id,
		nodes: []Access_Node,
		focus: Access_Id,
	) -> Error {
		target := find_window(p, window)
		if target == nil {return .Invalid_Window}
		if target.access == nil {
			if result := cosmos_uia_create(target.hwnd, target, access_request, &target.access); result < 0 {
				log.errorf("creating the UI Automation provider failed: HRESULT 0x%x", u32(result))
				return .Os
			}
			p.access_used = true
		}
		result := cosmos_uia_set(target.access, raw_data(nodes), uint(len(nodes)), focus)
		if u32(result) == w.E_INVALIDARG {return .Invalid_Argument}
		if u32(result) == w.E_OUTOFMEMORY {return .Out_Of_Memory}
		if result < 0 {
			log.errorf("raising UI Automation events failed: HRESULT 0x%x", u32(result))
			return .Os
		}
		return .None
	}

	// Answers WM_GETOBJECT when it asks for UI Automation and the app has set a tree. Other object ids,
	// such as MSAA's OBJID_CLIENT, are left to DefWindowProc.
	@(private)
	access_answer :: proc(window: ^Window, wp: w.WPARAM, lp: w.LPARAM) -> (w.LRESULT, bool) {
		if window.access == nil || i32(lp) != UIA_ROOT_OBJECT_ID {return 0, false}
		return cosmos_uia_answer(window.access, wp, lp), true
	}

	@(private)
	access_request :: proc "c" (user: rawptr, id: Access_Id, request: Access_Request) {
		window := (^Window)(user)
		context = window.owner.callback_context
		switch request {
		case .Invoke:
			enqueue(window.owner, Access_Invoke_Event{window.id, id, .Invoke})
		case .Toggle:
			enqueue(window.owner, Access_Invoke_Event{window.id, id, .Toggle})
		case .Expand:
			enqueue(window.owner, Access_Invoke_Event{window.id, id, .Expand})
		case .Collapse:
			enqueue(window.owner, Access_Invoke_Event{window.id, id, .Collapse})
		case .Focus:
			enqueue(window.owner, Access_Focus_Event{window.id, id})
		}
	}

	// Takes the window's provider back from UI Automation before the window goes.
	@(private)
	access_destroy :: proc(p: ^Platform, window: ^Window) {
		if window.access == nil {return}
		if result := cosmos_uia_destroy(window.access); result < 0 {
			log.errorf("UiaDisconnectProvider failed: HRESULT 0x%x", u32(result))
			p.error = .Os
		}
		window.access = nil
	}

	// Releases what assistive technologies still hold of any window's provider.
	@(private, require_results)
	access_shutdown :: proc(p: ^Platform) -> Error {
		if !p.access_used {return .None}
		p.access_used = false
		if result := UiaDisconnectAllProviders(); result < 0 {
			log.errorf("UiaDisconnectAllProviders failed: HRESULT 0x%x", u32(result))
			return .Os
		}
		return .None
	}
}
