package platform

@(require) import "cosmos:com"
@(require) import "cosmos:input"
@(require) import "core:log"
@(require) import "core:sync"
@(require) import w "core:sys/windows"
@(require) import "core:thread"

@(require) foreign import pick_user32 "system:user32.lib"
@(require) foreign import pick_shell32 "system:shell32.lib"
@(require) foreign import pick_ole32 "system:ole32.lib"

// The Win32 backend; a headless build compiles another (see HEADLESS in platform.odin).
when !HEADLESS {
	@(default_calling_convention = "system", private)
	foreign pick_user32 {
		EnumThreadWindows :: proc(
			thread: w.DWORD,
			callback: proc "system" (w.HWND, w.LPARAM) -> w.BOOL,
			data: w.LPARAM,
		) -> w.BOOL ---
	}

	@(default_calling_convention = "system", private)
	foreign pick_shell32 {
		SHCreateItemFromParsingName :: proc(
			path: w.LPCWSTR,
			context_: rawptr,
			iid: ^w.GUID,
			item: ^rawptr,
		) -> w.HRESULT ---
	}

	@(default_calling_convention = "system", private)
	foreign pick_ole32 {
		CoTaskMemFree :: proc(memory: rawptr) ---
	}

	@(private)
	Shell_Item :: struct #raw_union {
		#subtype unknown: w.IUnknown,
		using vtable: ^Shell_Item_Vtable,
	}
	@(private)
	Shell_Item_Vtable :: struct {
		using unknown_vtable: w.IUnknown_VTable,
		BindToHandler, GetParent: rawptr,
		GetDisplayName: proc "system" (this: ^Shell_Item, name_kind: u32, name: ^[^]u16) -> w.HRESULT,
		GetAttributes, Compare: rawptr,
	}
	@(private)
	Shell_Item_Array :: struct #raw_union {
		#subtype unknown: w.IUnknown,
		using vtable: ^Shell_Item_Array_Vtable,
	}
	@(private)
	Shell_Item_Array_Vtable :: struct {
		using unknown_vtable: w.IUnknown_VTable,
		BindToHandler, GetPropertyStore, GetPropertyDescriptionList, GetAttributes: rawptr,
		GetCount: proc "system" (this: ^Shell_Item_Array, count: ^w.DWORD) -> w.HRESULT,
		GetItemAt: proc "system" (this: ^Shell_Item_Array, index: w.DWORD, item: ^^Shell_Item) -> w.HRESULT,
		EnumItems: rawptr,
	}
	// IFileDialog, which both the open and the save dialog are, and then IFileOpenDialog's GetResults,
	// which only an open dialog has.
	@(private)
	File_Dialog :: struct #raw_union {
		#subtype unknown: w.IUnknown,
		using vtable: ^File_Dialog_Vtable,
	}
	@(private)
	File_Dialog_Vtable :: struct {
		using unknown_vtable: w.IUnknown_VTable,
		Show: proc "system" (this: ^File_Dialog, owner: w.HWND) -> w.HRESULT,
		SetFileTypes: proc "system" (this: ^File_Dialog, count: u32, types: [^]w.COMDLG_FILTERSPEC) -> w.HRESULT,
		SetFileTypeIndex, GetFileTypeIndex, Advise, Unadvise: rawptr,
		SetOptions: proc "system" (this: ^File_Dialog, options: u32) -> w.HRESULT,
		GetOptions: proc "system" (this: ^File_Dialog, options: ^u32) -> w.HRESULT,
		SetDefaultFolder: rawptr,
		SetFolder: proc "system" (this: ^File_Dialog, item: ^Shell_Item) -> w.HRESULT,
		GetFolder, GetCurrentSelection: rawptr,
		SetFileName: proc "system" (this: ^File_Dialog, name: w.LPCWSTR) -> w.HRESULT,
		GetFileName, SetTitle, SetOkButtonLabel, SetFileNameLabel: rawptr,
		GetResult: proc "system" (this: ^File_Dialog, item: ^^Shell_Item) -> w.HRESULT,
		AddPlace: rawptr,
		SetDefaultExtension: proc "system" (this: ^File_Dialog, extension: w.LPCWSTR) -> w.HRESULT,
		Close, SetClientGuid, ClearClientData, SetFilter: rawptr,
		GetResults: proc "system" (this: ^File_Dialog, items: ^^Shell_Item_Array) -> w.HRESULT,
	}

	// A file dialog open on its own thread. The system dialog runs a modal loop, which on the UI thread
	// would stop every terminal from drawing until it closed; it disables only its owner window.
	File_Pick :: struct {
		thread:                       ^thread.Thread,
		platform:                     ^Platform,
		owner:                        w.HWND,
		mode:                         File_Pick_Mode,
		filters:                      []w.COMDLG_FILTERSPEC,
		directory, file_name, extension: cstring16,
		// What the dialog chose, written by its thread before `done`.
		paths:                        [dynamic]string,
		thread_id:                    w.DWORD,
		done:                         bool,
	}

	@(private)
	file_pick_run :: proc(t: ^thread.Thread) {
		pick := (^File_Pick)(t.data)
		sync.atomic_store(&pick.thread_id, w.GetCurrentThreadId())
		defer {
			sync.atomic_store(&pick.done, true)
			// The UI thread's event wait collects the result.
			if wake(pick.platform) != .None {log.error("waking the loop after a file dialog failed")}
		}
		// The shell's item dialog needs an apartment on the thread that shows it.
		initialized, _ := com.apartment()
		defer if initialized {w.CoUninitialize()}
		file_pick_show(pick)
	}

	// Shows the shell's item dialog, IFileOpenDialog or IFileSaveDialog, as the pick's mode asks.
	@(private)
	file_pick_show :: proc(pick: ^File_Pick) {
		open_class := w.GUID{0xdc1c5a9c, 0xe88a, 0x4dde, {0xa5, 0xa1, 0x60, 0xf8, 0x2a, 0x20, 0xae, 0xf7}}
		open_id := w.GUID{0xd57c7288, 0xd4ad, 0x4768, {0xbe, 0x02, 0x9d, 0x96, 0x95, 0x32, 0xd9, 0x60}}
		save_class := w.GUID{0xc0b4e2f3, 0xba21, 0x4773, {0x8d, 0xba, 0x33, 0x5e, 0xc9, 0x46, 0xeb, 0x8b}}
		save_id := w.GUID{0x84bccd23, 0x5fde, 0x4cdb, {0xae, 0xa4, 0xaf, 0x64, 0xb8, 0x3d, 0x78, 0xab}}
		item_id := w.GUID{0x43826d1e, 0xe718, 0x42ee, {0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b, 0xfe}}
		saving := pick.mode == .Save
		object: rawptr
		class_id, dialog_id := saving ? save_class : open_class, saving ? save_id : open_id
		result := w.CoCreateInstance(&class_id, nil, w.CLSCTX_INPROC_SERVER, &dialog_id, &object)
		if result < 0 || object == nil {
			log.errorf("CoCreateInstance(%s) failed: %x", saving ? "FileSaveDialog" : "FileOpenDialog", u32(result))
			return
		}
		dialog := (^File_Dialog)(object)
		defer dialog->Release()
		// Without FOS_NOCHANGEDIR the dialog changes the process's working directory, which new shells
		// inherit.
		FOS_OVERWRITEPROMPT :: 0x2
		FOS_NOCHANGEDIR :: 0x8
		FOS_PICKFOLDERS :: 0x20
		FOS_FORCEFILESYSTEM :: 0x40
		FOS_ALLOWMULTISELECT :: 0x200
		FOS_PATHMUSTEXIST :: 0x800
		FOS_FILEMUSTEXIST :: 0x1000
		options: u32
		if result = dialog->GetOptions(&options); result < 0 {
			log.errorf("IFileDialog.GetOptions failed: %x", u32(result))
			return
		}
		options |= FOS_NOCHANGEDIR | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST
		switch pick.mode {
		case .Open: options |= FOS_FILEMUSTEXIST
		case .Open_Many: options |= FOS_FILEMUSTEXIST | FOS_ALLOWMULTISELECT
		case .Save: options |= FOS_OVERWRITEPROMPT
		case .Folder: options |= FOS_PICKFOLDERS
		}
		if result = dialog->SetOptions(options); result < 0 {
			log.errorf("IFileDialog.SetOptions failed: %x", u32(result))
			return
		}
		if pick.mode != .Folder && len(pick.filters) > 0 {
			if result = dialog->SetFileTypes(u32(len(pick.filters)), raw_data(pick.filters)); result < 0 {
				log.errorf("IFileDialog.SetFileTypes failed: %x", u32(result))
				return
			}
		}
		if pick.file_name != nil {
			if result = dialog->SetFileName(pick.file_name); result < 0 {
				log.errorf("IFileDialog.SetFileName failed: %x", u32(result))
			}
		}
		if pick.extension != nil {
			if result = dialog->SetDefaultExtension(pick.extension); result < 0 {
				log.errorf("IFileDialog.SetDefaultExtension failed: %x", u32(result))
			}
		}
		if pick.directory != nil {
			start: rawptr
			// A start folder that has gone only costs the dialog its starting place.
			if SHCreateItemFromParsingName(pick.directory, nil, &item_id, &start) >= 0 && start != nil {
				folder := (^Shell_Item)(start)
				defer folder->Release()
				if result = dialog->SetFolder(folder); result < 0 {
					log.errorf("IFileDialog.SetFolder failed: %x", u32(result))
				}
			}
		}
		// HRESULT_FROM_WIN32(ERROR_CANCELLED), which Show returns when the user closes the dialog.
		CANCELLED :: u32(0x800704C7)
		if result = dialog->Show(pick.owner); result < 0 {
			if u32(result) != CANCELLED {log.errorf("IFileDialog.Show failed: %x", u32(result))}
			return
		}
		if pick.mode != .Open_Many {
			chosen: ^Shell_Item
			if result = dialog->GetResult(&chosen); result < 0 || chosen == nil {
				log.errorf("IFileDialog.GetResult failed: %x", u32(result))
				return
			}
			defer chosen->Release()
			file_pick_keep(pick, chosen)
			return
		}
		items: ^Shell_Item_Array
		if result = dialog->GetResults(&items); result < 0 || items == nil {
			log.errorf("IFileOpenDialog.GetResults failed: %x", u32(result))
			return
		}
		defer items->Release()
		count: w.DWORD
		if result = items->GetCount(&count); result < 0 {
			log.errorf("IShellItemArray.GetCount failed: %x", u32(result))
			return
		}
		for index in 0 ..< count {
			item: ^Shell_Item
			if result = items->GetItemAt(index, &item); result < 0 || item == nil {
				log.errorf("IShellItemArray.GetItemAt failed: %x", u32(result))
				continue
			}
			file_pick_keep(pick, item)
			item->Release()
		}
	}

	// Adds the file system path of `item` to what the pick chose.
	@(private)
	file_pick_keep :: proc(pick: ^File_Pick, item: ^Shell_Item) {
		SIGDN_FILESYSPATH :: 0x80058000
		name: [^]u16
		if result := item->GetDisplayName(SIGDN_FILESYSPATH, &name); result < 0 || name == nil {
			log.errorf("IShellItem.GetDisplayName failed: %x", u32(result))
			return
		}
		defer CoTaskMemFree(name)
		length := 0
		for name[length] != 0 {length += 1}
		path, err := w.utf16_to_utf8(name[:length], context.allocator)
		if err != nil {return}
		if _, append_error := append(&pick.paths, path); append_error != nil {delete(path)}
	}

	// Opens a dialog owned by the window. Returns nil when it could not start.
	@(require_results)
	file_pick_start :: proc(p: ^Platform, id: input.Window_Id, options: File_Pick_Options) -> ^File_Pick {
		window := find_window(p, id)
		if window == nil {return nil}
		pick, err := new(File_Pick)
		if err != nil {return nil}
		pick.platform, pick.owner, pick.mode = p, window.hwnd, options.mode
		ok := true
		if len(options.filters) > 0 {
			filters, filters_error := make([]w.COMDLG_FILTERSPEC, len(options.filters))
			if filters_error != nil {ok = false}
			pick.filters = filters
			for filter, i in options.filters {
				if !ok {break}
				pick.filters[i].pszName = w.utf8_to_wstring(filter.name, context.allocator)
				pick.filters[i].pszSpec = w.utf8_to_wstring(filter.pattern, context.allocator)
				ok = pick.filters[i].pszName != nil && pick.filters[i].pszSpec != nil
			}
		}
		wide :: proc(text: string, ok: ^bool) -> cstring16 {
			if text == "" {return nil}
			converted := w.utf8_to_wstring(text, context.allocator)
			if converted == nil {ok^ = false}
			return converted
		}
		pick.directory = wide(options.directory, &ok)
		pick.file_name = wide(options.file_name, &ok)
		pick.extension = wide(options.default_extension, &ok)
		if ok {pick.thread = thread.create(file_pick_run)}
		if pick.thread == nil {
			file_pick_destroy(pick)
			return nil
		}
		pick.thread.data = pick
		pick.thread.init_context = context
		thread.start(pick.thread)
		return pick
	}

	// Whether the dialog has closed, and what it chose: none when it was cancelled. The paths belong to
	// the pick.
	@(require_results)
	file_pick_finished :: proc(pick: ^File_Pick) -> (paths: []string, finished: bool) {
		if !sync.atomic_load(&pick.done) {return nil, false}
		return pick.paths[:], true
	}

	// Closes a dialog that is still open, waits for its thread and frees the pick. A dialog whose owner
	// still exists sends it messages while it opens and closes, so the wait answers those without
	// taking any posted message off the queue.
	file_pick_destroy :: proc(pick: ^File_Pick) {
		if pick.thread != nil {
			for !thread.is_done(pick.thread) {
				if id := sync.atomic_load(&pick.thread_id); id != 0 {
					EnumThreadWindows(id, proc "system" (window: w.HWND, _: w.LPARAM) -> w.BOOL {
						w.PostMessageW(window, w.WM_CLOSE, 0, 0)
						return true
					}, 0)
				}
				message: w.MSG
				w.PeekMessageW(&message, nil, 0, 0, w.PM_NOREMOVE | w.PM_QS_SENDMESSAGE)
				w.Sleep(10)
			}
			thread.destroy(pick.thread)
		}
		for path in pick.paths {delete(path)}
		delete(pick.paths)
		for filter in pick.filters {
			if filter.pszName != nil {free(rawptr(filter.pszName))}
			if filter.pszSpec != nil {free(rawptr(filter.pszSpec))}
		}
		delete(pick.filters)
		for text in ([?]cstring16{pick.directory, pick.file_name, pick.extension}) {
			if text != nil {free(rawptr(text))}
		}
		free(pick)
	}
}
