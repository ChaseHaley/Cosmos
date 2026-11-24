package render

import "core:log"
import d3d "vendor:directx/d3d11"

// Textures for images a program put on the screen. They are keyed by a value the caller guarantees
// is never reused for different pixels, so a stale entry can only waste memory, never draw wrongly.
// Frames normally reference what they need, so anything left unreferenced for a while can go.

// GPU memory kept for images not drawn in the current frame. What is on screen is always kept.
IMAGE_BUDGET_BYTES :: 256 << 20
// How long an undrawn texture survives under budget, so scrolling back and forth does not reupload.
IMAGE_IDLE_FRAMES :: 60

@(private)
Image_Texture :: struct {
	texture:       ^d3d.ITexture2D,
	// Nil records a texture that could not be created, so a frame does not retry and log forever.
	view:          ^d3d.IShaderResourceView,
	bytes:         int,
	last_used:     u64,
	width, height: int,
	// An image_target texture: a foreign renderer owns its pixels, and only image_target_release frees it.
	pinned:        bool,
}

// image_known reports whether image_upload has settled this key, even if the upload failed.
@(require_results)
image_known :: proc(d: ^Device, key: u64) -> bool {
	return key in d.images
}

// image_epoch changes whenever a texture is evicted, so a retained draw list naming it can be rebuilt.
@(require_results)
image_epoch :: proc(d: ^Device) -> u64 {
	return d.image_epoch
}

// image_upload creates a texture from premultiplied RGBA, replacing any texture the key named. A failure
// is recorded and logged here rather than returned: one bad image must not stop the terminal drawing.
image_upload :: proc(d: ^Device, key: u64, width, height: int, pixels: []u8) {
	// A target's foreign renderer may still be drawing into it, so an upload must never free one.
	assert(key & (IMAGE_KEY_RENDERED | IMAGE_KEY_TARGET) == 0, "image_upload keys set neither key bit")
	assert(len(pixels) == width * height * 4)
	if old, known := d.images[key]; known {
		d.image_bytes -= old.bytes
		image_release(&old)
		delete_key(&d.images, key)
	}
	entry := Image_Texture {
		last_used = d.image_frame,
	}
	if err := image_texture_create(d, &entry, width, height, pixels); err != .None {
		log.errorf("render: creating a %dx%d image texture failed: %v", width, height, err)
		image_release(&entry)
		entry = {
			last_used = d.image_frame,
		}
	}
	d.image_bytes += entry.bytes
	d.images[key] = entry
}

// image_render draws `list` into a new width x height texture under `key`, replacing any texture the key
// named, for push_image to show, as an image or as dust. The key must have IMAGE_KEY_RENDERED set. The
// list draws as a frame would, over transparent pixels, so the texture is premultiplied like an upload.
@(require_results)
image_render :: proc(d: ^Device, key: u64, width, height: int, list: ^Draw_List) -> Error {
	assert(key & IMAGE_KEY_RENDERED != 0, "image_render keys set IMAGE_KEY_RENDERED")
	if d.lost {return .Device_Lost}
	if old, known := d.images[key]; known {
		d.image_bytes -= old.bytes
		image_release(&old)
		delete_key(&d.images, key)
	}
	if width < 1 ||
	   height < 1 ||
	   width > d3d.REQ_TEXTURE2D_U_OR_V_DIMENSION ||
	   height > d3d.REQ_TEXTURE2D_U_OR_V_DIMENSION {
		return .Invalid_Argument
	}
	entry := Image_Texture {
		last_used = d.image_frame,
		width     = width,
		height    = height,
		bytes     = width * height * 4,
	}
	ok := false
	defer if !ok {image_release(&entry)}
	desc := d3d.TEXTURE2D_DESC {
		Width = u32(width),
		Height = u32(height),
		MipLevels = 1,
		ArraySize = 1,
		Format = .R8G8B8A8_UNORM,
		SampleDesc = {Count = 1},
		BindFlags = {.SHADER_RESOURCE, .RENDER_TARGET},
	}
	hr := d.native->CreateTexture2D(&desc, nil, &entry.texture)
	if err := checked(d, hr, "CreateTexture2D rendered image"); err != .None {return err}
	hr = d.native->CreateShaderResourceView(entry.texture, nil, &entry.view)
	if err := checked(d, hr, "CreateShaderResourceView rendered image"); err != .None {return err}
	target: ^d3d.IRenderTargetView
	hr = d.native->CreateRenderTargetView(entry.texture, nil, &target)
	if err := checked(d, hr, "CreateRenderTargetView rendered image"); err != .None {return err}
	defer release(target)
	if err := list_draw(d, target, i32(width), i32(height), list, {}); err != .None {return err}
	ok = true
	d.image_bytes += entry.bytes
	d.images[key] = entry
	return .None
}

// image_target makes a width x height texture under `key` for a renderer outside this package to draw
// into, such as a video player, and returns its ID3D11Texture2D: R8G8B8A8_UNORM, one mip, bound as a
// render target and a shader resource, premultiplied like any image. A key already in use is replaced,
// so calling it again at a new size resizes. push_image shows it like any image.
//
// The texture is pinned: eviction and the image budget leave it alone until image_target_release. The
// renderer draws with this device's immediate context, on the thread that builds and renders frames and
// between frames; render sets every pipeline state it uses on each pass, so the renderer may leave state
// behind, except in the geometry, hull and domain stages, which render never sets. After device loss,
// make the target again on the new device.
@(require_results)
image_target :: proc(d: ^Device, key: u64, width, height: int) -> (texture: rawptr, err: Error) {
	assert(key & IMAGE_KEY_TARGET != 0, "image_target keys set IMAGE_KEY_TARGET")
	if d.lost {return nil, .Device_Lost}
	image_target_release(d, key)
	if width < 1 ||
	   height < 1 ||
	   width > d3d.REQ_TEXTURE2D_U_OR_V_DIMENSION ||
	   height > d3d.REQ_TEXTURE2D_U_OR_V_DIMENSION {
		return nil, .Invalid_Argument
	}
	entry := Image_Texture {
		last_used = d.image_frame,
		width     = width,
		height    = height,
		bytes     = width * height * 4,
		pinned    = true,
	}
	ok := false
	defer if !ok {image_release(&entry)}
	desc := d3d.TEXTURE2D_DESC {
		Width = u32(width),
		Height = u32(height),
		MipLevels = 1,
		ArraySize = 1,
		Format = .R8G8B8A8_UNORM,
		SampleDesc = {Count = 1},
		BindFlags = {.SHADER_RESOURCE, .RENDER_TARGET},
	}
	hr := d.native->CreateTexture2D(&desc, nil, &entry.texture)
	if err = checked(d, hr, "CreateTexture2D target image"); err != .None {return nil, err}
	hr = d.native->CreateShaderResourceView(entry.texture, nil, &entry.view)
	if err = checked(d, hr, "CreateShaderResourceView target image"); err != .None {return nil, err}
	ok = true
	d.images[key] = entry
	return entry.texture, .None
}

// image_target_release frees the texture image_target made under `key`; any other key is left alone.
image_target_release :: proc(d: ^Device, key: u64) {
	if entry, known := d.images[key]; known && entry.pinned {
		image_release(&entry)
		delete_key(&d.images, key)
	}
}

@(private, require_results)
image_texture_create :: proc(
	d: ^Device,
	entry: ^Image_Texture,
	width, height: int,
	pixels: []u8,
) -> Error {
	if width < 1 ||
	   height < 1 ||
	   width > d3d.REQ_TEXTURE2D_U_OR_V_DIMENSION ||
	   height > d3d.REQ_TEXTURE2D_U_OR_V_DIMENSION {
		return .Invalid_Argument
	}
	// A full mip chain keeps a large image from shimmering when placed small; drawn 1:1 it samples
	// the top level exactly.
	desc := d3d.TEXTURE2D_DESC {
		Width = u32(width),
		Height = u32(height),
		MipLevels = 0,
		ArraySize = 1,
		Format = .R8G8B8A8_UNORM,
		SampleDesc = {Count = 1},
		BindFlags = {.SHADER_RESOURCE, .RENDER_TARGET},
		MiscFlags = {.GENERATE_MIPS},
	}
	if err := checked(d, d.native->CreateTexture2D(&desc, nil, &entry.texture), "CreateTexture2D image");
	   err != .None {
		return err
	}
	hr := d.native->CreateShaderResourceView(entry.texture, nil, &entry.view)
	if err := checked(d, hr, "CreateShaderResourceView image"); err != .None {
		return err
	}
	d.ctx->UpdateSubresource(entry.texture, 0, nil, raw_data(pixels), u32(width * 4), 0)
	d.ctx->GenerateMips(entry.view)
	entry.bytes = len(pixels) * 4 / 3
	entry.width, entry.height = width, height
	return .None
}

@(private)
image_release :: proc(entry: ^Image_Texture) {
	release(entry.view)
	release(entry.texture)
	entry.view, entry.texture = nil, nil
}

@(private)
images_destroy :: proc(d: ^Device) {
	for _, &entry in d.images {
		image_release(&entry)
	}
	delete(d.images)
}

// images_evict runs after each frame: the oldest undrawn texture goes first, while it has sat idle
// too long or the budget is exceeded. Anything the frame just drew is out of reach.
@(private)
images_evict :: proc(d: ^Device) {
	for {
		oldest_key, oldest, found := u64(0), max(u64), false
		for key, entry in d.images {
			if !entry.pinned && entry.last_used < d.image_frame && entry.last_used < oldest {
				oldest_key, oldest, found = key, entry.last_used, true
			}
		}
		if !found {return}
		if d.image_frame - oldest <= IMAGE_IDLE_FRAMES && d.image_bytes <= d.image_budget {return}
		entry := d.images[oldest_key]
		if entry.view != nil {d.image_epoch += 1}
		d.image_bytes -= entry.bytes
		image_release(&entry)
		delete_key(&d.images, oldest_key)
	}
}
