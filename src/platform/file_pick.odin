package platform

// What a file dialog chooses.
File_Pick_Mode :: enum u8 {
	// One existing file.
	Open,
	// One or more existing files.
	Open_Many,
	// A file to write, which may not exist yet; the dialog asks before replacing one that does.
	Save,
	// One existing folder.
	Folder,
}

// A file type the dialog offers: `name` describes the semicolon-separated `pattern`, such as
// {"Videos", "*.mp4;*.mkv"}.
File_Filter :: struct {
	name, pattern: string,
}

File_Pick_Options :: struct {
	mode:              File_Pick_Mode,
	// The types to choose from, the first selected; none offers every file. A folder dialog has none.
	filters:           []File_Filter,
	// Where the dialog starts; empty leaves it to the system, which remembers the last place.
	directory:         string,
	// The name a save dialog suggests.
	file_name:         string,
	// What a save dialog appends to a name typed without an extension, without the dot, such as "mp4".
	default_extension: string,
}
