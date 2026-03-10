/*
This atlas builder looks into a 'textures' folder for pngs, ase and aseprite 
files and makes an atlas from those. It outputs both `atlas.png` and
`atlas.odin`. The odin file you compile as part of your game. It contains
metadata about where in the atlas the textures ended up.

See README.md for additional documentation.

Uses aseprite loader by blob1807: https://github.com/blob1807/odin-aseprite

By Karl Zylinski, http://zylinski.se
*/

package atlas_builder

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:image/png"
import "core:log"
import "core:os"
import "core:path/slashpath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import ase "aseprite"
import stbim "vendor:stb/image"
import stbrp "vendor:stb/rect_pack"
import stbtt "vendor:stb/truetype"

// ---------------------
// CONFIGURATION OPTIONS
// ---------------------

// Size of atlas in NxN pixels. Note: The outputted atlas PNG is cropped to the visible pixels.
ATLAS_SIZE :: 512

// Path to output final atlas PNG to
ATLAS_PNG_OUTPUT_PATH :: "atlas.png"

// Path to output atlas Odin metadata file to. Compile this as part of your game to get metadata
// about where in atlas your textures etc are.
ATLAS_ODIN_OUTPUT_PATH :: "atlas.odin"

// Set to false to not crop atlas after generation.
ATLAS_CROP :: true

// The NxN size of each tile (you can import tilesets by giving textures the prefix `tileset_`)
// Note that the width and height of the tileset image must be multiple of TILE_SIZE.
TILE_SIZE :: 8

// Add padding to tiles by adding a pixel border around it and copying there.
// This helps with bleeding when doing subpixel camera movements.
TILE_ADD_PADDING :: true

// for package line at top of atlas Odin metadata file
PACKAGE_NAME :: "game"

// The folder within which to look for textures
TEXTURES_DIR :: "textures"

// The letters to extract from the font
LETTERS_IN_FONT :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890?!&.,_:[]-+"

// The font to extract letters from
FONT_FILENAME :: "font.ttf"

// The font size of letters extracted from font
FONT_SIZE :: 32


// ---------------------
// ATLAS BUILDER PROGRAM
// ---------------------

Vec2i :: [2]int

Rect :: struct {
	x, y, width, height: int,
}

Color :: [4]u8

// Note that types such as Atlas_Texture_Rect are internal types used during the
// atlas generation. The types written into the atlas.odin file are similar but
// may be slightly different, see the end of `main` where .odin file is written.

Atlas_Texture_Rect :: struct {
	rect: Rect,
	size: Vec2i,
	offset_top: int,
	offset_right: int,
	offset_bottom: int,
	offset_left: int,
	name: string,
	duration: f32,
}

Atlas_Tile_Rect :: struct {
	rect: Rect,
	coord: Vec2i,
}

Glyph :: struct {
	value: rune,
	image: Image,
	offset: Vec2i,
	advance_x: int,
}

Atlas_Glyph :: struct {
	rect: Rect,
	glyph: Glyph,
}

Texture_Data :: struct {
	source_size: Vec2i,
	source_offset: Vec2i,
	document_size: Vec2i,
	offset: Vec2i,
	name: string,
	pixels_size: Vec2i,
	pixels: []Color,
	duration: f32,
	is_tile: bool,
	tile_coord: Vec2i,
}

Tileset :: struct {
	name: string,
	pixels: []Color,
	pixels_size: Vec2i,
	visible_pixels_size: Vec2i,
	offset: Vec2i,
	packed_rects: [dynamic]Atlas_Tile_Rect,
}

Animation :: struct {
	name: string,
	first_texture: string,
	last_texture: string,
	document_size: Vec2i,
	loop_direction: ase.Tag_Loop_Dir,
	repeat: u16,
}

Image :: struct {
	data: []Color,
	width: int,
	height: int,
}

Color_F32 :: [4]f32

color_f32 :: proc(c: Color) -> Color_F32 {
	return {
		f32(c.r) / 255,
		f32(c.g) / 255,
		f32(c.b) / 255,
		f32(c.a) / 255,
	}
}

color_from_f32 :: proc(c: Color_F32) -> Color {
	return {
		u8(c.r * 255),
		u8(c.g * 255),
		u8(c.b * 255),
		u8(c.a * 255),
	}
}

draw_image :: proc(to: ^Image, from: Image, source: Rect, pos: Vec2i) {
	for sxf in 0..<source.width {
		for syf in 0..<source.height {
			sx := int(source.x+sxf)
			sy := int(source.y+syf)

			if sx < 0 || sx >= from.width {
				continue
			}

			if sy < 0 || sy >= from.height {
				continue
			}

			dx := pos.x + int(sxf)
			dy := pos.y + int(syf)

			if dx < 0 || dx >= to.width {
				continue
			}

			if dy < 0 || dy >= to.height {
				continue
			}

			from_idx := sy * from.width + sx
			to_idx := dy * to.width + dx


			if to.data[to_idx].a == 0 {
				to.data[to_idx] = from.data[from_idx]
			} else {
				f := color_f32(from.data[from_idx])
				t := color_f32(to.data[to_idx])

				to.data[to_idx] = color_from_f32(t*(1-f.a) + f*f.a)
			}
		}
	}
}

draw_image_rectangle :: proc(to: ^Image, rect: Rect, color: Color) {
	for dxf in 0..<rect.width {
		for dyf in 0..<rect.height {
			dx := int(rect.x) + int(dxf)
			dy := int(rect.y) + int(dyf)

			if dx < 0 || dx >= to.width {
				continue
			}

			if dy < 0 || dy >= to.height {
				continue
			}

			to_idx := dy * to.width + dx
			to.data[to_idx] = color
		}
	}
}

get_image_pixel :: proc(img: Image, x: int, y: int) -> Color {
	idx := img.width * y + x

	if idx < 0 || idx >= len(img.data) {
		return {}
	}

	return img.data[idx]
}

// Returns the format I want for names in atlas.odin. Takes the name from a path
// and turns it from player_jump.png to Player_Jump.
asset_name :: proc(path: string) -> string {
	return fmt.tprintf("%s", strings.to_ada_case(slashpath.name(slashpath.base(path))))
}

load_png_tileset :: proc(filename: string) -> (Tileset, bool) {
	data, data_ok := os.read_entire_file(filename)

	if !data_ok {
		log.error("Failed loading tileset", filename)
		return {}, false
	}

	defer delete(data)

	img, err := png.load_from_bytes(data)

	if err != nil {
		log.error("PNG load error", err)
		return {}, false
	}

	defer png.destroy(img)

	if img.depth != 8 && img.channels != 4 {
		log.error(
			"Only 8 bpp, 4 channels PNG supported (this can probably be fixed by doing some work in `load_png_texture_data`",
		)
		return {}, false
	}

	assert(img.width % TILE_SIZE == 0, "Tileset width is not divisbile by TILE_SIZE!")
	assert(img.height % TILE_SIZE == 0, "Tileset height is not divisbile by TILE_SIZE!")

	t := Tileset {
		pixels = slice.clone(slice.reinterpret([]Color, img.pixels.buf[:])),
		offset = {0, 0},
		pixels_size = {img.width, img.height},
		visible_pixels_size = {img.width, img.height},
	}

	return t, true
}

// Loads a tileset. Currently only supports .ase tilesets
load_tileset :: proc(filename: string) -> (Tileset, bool) {
	data, data_ok := os.read_entire_file(filename)

	if !data_ok {
		log.error("Failed loading tileset", filename)
		return {}, false
	}

	defer delete(data)
	doc: ase.Document

	umerr := ase.unmarshal(&doc, data[:])
	if umerr != nil {
		log.error("Aseprite unmarshal error", umerr)
		return {}, false
	}

	defer ase.destroy_doc(&doc)

	indexed := doc.header.color_depth == .Indexed
	palette: ase.Palette_Chunk
	if indexed {
		for f in doc.frames {
			for c in f.chunks {
				if p, ok := c.(ase.Palette_Chunk); ok {
					palette = p
					break
				}
			}
		}
	}
	
	if indexed && len(palette.entries) == 0 {
		log.error("Document is indexed, but found no palette!")
	}

	combined_layers := Image {
		data = make([]Color, int(doc.header.width*doc.header.height)),
		width = int(doc.header.width),
		height = int(doc.header.height),
	}

	for f in doc.frames {
		for c in f.chunks {
			#partial switch cv in c {
				case ase.Cel_Chunk:
					if cl, ok := cv.cel.(ase.Com_Image_Cel); ok {
						cel_pixels: []Color

						if indexed {
							cel_pixels = make([]Color, int(cl.width) * int(cl.height))
							for p, idx in cl.pixels {
								if p == 0 {
									continue
								}
								
								cel_pixels[idx] = Color(palette.entries[u32(p)].color)
							}
						} else {
							cel_pixels = slice.reinterpret([]Color, cl.pixels)
						}

						from := Image {
							data = cel_pixels,
							width = int(cl.width),
							height = int(cl.height),
						}

						source := Rect {
							0, 0,
							int(cl.width), int(cl.height),
						}

						dest_pos := Vec2i {
							int(cv.x),
							int(cv.y),
						}

						draw_image(&combined_layers, from, source, dest_pos)
					}
			}
		}
	}


	t := Tileset {
		pixels = combined_layers.data,
		pixels_size = { combined_layers.width, combined_layers.height },
		visible_pixels_size = { combined_layers.width, combined_layers.height },
	}

	return t, true
}

load_ase_texture_data :: proc(filename: string, textures: ^[dynamic]Texture_Data, animations: ^[dynamic]Animation) {
	data, data_ok := os.read_entire_file(filename)

	if !data_ok {
		return
	}

	doc: ase.Document

	umerr := ase.unmarshal(&doc, data[:])
	if umerr != nil {
		log.error("Aseprite unmarshal error", umerr)
		return
	}

	defer ase.destroy_doc(&doc)

	document_rect := Rect {
		0, 0,
		int(doc.header.width), int(doc.header.height),
	}

	base_name := asset_name(filename)
	frame_idx := 0
	animated := len(doc.frames) > 1
	skip_writing_main_anim := false
	indexed := doc.header.color_depth == .Indexed
	palette: ase.Palette_Chunk
	if indexed {
		for f in doc.frames {
			for c in f.chunks {
				if p, ok := c.(ase.Palette_Chunk); ok {
					palette = p
					break
				}
			}
		}
	}
	
	if indexed && len(palette.entries) == 0 {
		log.error("Document is indexed, but found no palette!")
	}

	visible_layers := make(map[u16]bool)
	defer delete(visible_layers)
	layer_index : u16
	for f in doc.frames {
		for &c in f.chunks {
			#partial switch &c in c {
			case ase.Layer_Chunk:
				if ase.Layer_Chunk_Flag.Visiable in c.flags {
					visible_layers[layer_index] = true
				}
				layer_index += 1
			}
		}
	}

	if len(visible_layers) == 0 {
		log.error("No visible layers in document", filename)
		return
	}
	
	for f in doc.frames {
		duration: f32 = f32(f.header.duration)/1000.0

		cels: [dynamic]^ase.Cel_Chunk
		cel_min := Vec2i { max(int), max(int) }
		cel_max := Vec2i { min(int), min(int) }

		for &c in f.chunks {
			#partial switch &c in c {
			case ase.Cel_Chunk:
				if c.layer_index in visible_layers {
					if cl, ok := &c.cel.(ase.Com_Image_Cel); ok {
						cel_min.x = min(cel_min.x, int(c.x))
						cel_min.y = min(cel_min.y, int(c.y))
						cel_max.x = max(cel_max.x, int(c.x) + int(cl.width))
						cel_max.y = max(cel_max.y, int(c.y) + int(cl.height))
						append(&cels, &c)
					}
				}
			case ase.Tags_Chunk:
				for tag in c {
					a := Animation {
						name = fmt.tprint(base_name, strings.to_ada_case(tag.name), sep = "_"),
						first_texture = fmt.tprint(base_name, tag.from_frame, sep = ""),
						last_texture = fmt.tprint(base_name, tag.to_frame, sep = ""),
						loop_direction = tag.loop_direction,
						repeat = tag.repeat,
					}
					
					skip_writing_main_anim = true
					append(animations, a)
				}
			}
		}

		if len(cels) == 0 {
			continue
		}

		slice.sort_by(cels[:], proc(i, j: ^ase.Cel_Chunk) -> bool {
			return i.layer_index < j.layer_index
		})

		s := cel_max - cel_min
		pixels := make([]Color, int(s.x*s.y))

		combined_layers := Image {
			data = pixels,
			width = s.x,
			height = s.y,
		}

		for c in cels {
			cl := c.cel.(ase.Com_Image_Cel)
			cel_pixels: []Color

			if indexed {
				cel_pixels = make([]Color, int(cl.width) * int(cl.height))
				for p, idx in cl.pixels {
					if p == 0 {
						continue
					}
					
					cel_pixels[idx] = Color(palette.entries[u32(p)].color)
				}
			} else {
				cel_pixels = slice.reinterpret([]Color, cl.pixels)
			}

			source := Rect {
				0, 0,
				int(cl.width), int(cl.height),
			}

			from := Image {
				data = cel_pixels,
				width = int(cl.width),
				height = int(cl.height),
			}

			dest_pos := Vec2i {
				int(c.x) - cel_min.x,
				int(c.y) - cel_min.y,
			}

			draw_image(&combined_layers, from, source, dest_pos)
		}

		cels_rect := Rect {
			cel_min.x, cel_min.y,
			s.x, s.y,
		}

		rect_intersect :: proc(r1, r2: Rect) -> Rect {
			x1 := max(r1.x, r2.x)
			y1 := max(r1.y, r2.y)
			x2 := min(r1.x + r1.width, r2.x + r2.width)
			y2 := min(r1.y + r1.height, r2.y + r2.height)
			if x2 < x1 { x2 = x1 }
			if y2 < y1 { y2 = y1 }
			return {x1, y1, x2 - x1, y2 - y1}
		}

		source_rect := rect_intersect(cels_rect, document_rect)

		td := Texture_Data {
			source_size = { int(source_rect.width), int(source_rect.height)},
			source_offset = { int(source_rect.x - cels_rect.x), int(source_rect.y - cels_rect.y) },
			pixels_size = s,
			document_size = {int(doc.header.width), int(doc.header.height)},
			duration = duration,
			name = animated ? fmt.tprint(base_name, frame_idx, sep = "") : base_name,
			pixels = pixels,
		}

		if cel_min.x > 0 {
			td.offset.x = cel_min.x
		}

		if cel_min.y > 0 {
			td.offset.y = cel_min.y
		}

		append(textures, td)
		frame_idx += 1
	}

	if animated && frame_idx > 1 && !skip_writing_main_anim {
		a := Animation {
			name = base_name,
			first_texture = fmt.tprint(base_name, 0, sep = ""),
			last_texture = fmt.tprint(base_name, frame_idx - 1, sep = ""),
			document_size = {int(document_rect.width), int(document_rect.height)},
		}

		append(animations, a)
	}
}

load_png_texture_data :: proc(filename: string, textures: ^[dynamic]Texture_Data) {
	data, data_ok := os.read_entire_file(filename)

	if !data_ok {
		log.error("Failed loading tileset", filename)
		return
	}

	defer delete(data)

	img, err := png.load_from_bytes(data)

	if err != nil {
		log.error("PNG load error", err)
		return
	}

	defer png.destroy(img)

	if img.depth != 8 && img.channels != 4 {
		log.error("Only 8 bpp, 4 channels PNG supported (this can probably be fixed by doing some work in `load_png_texture_data`")
		return
	}

	td := Texture_Data {
		source_size = {img.width, img.height},
		pixels_size = {img.width, img.height},
		document_size = {img.width, img.height},
		duration = 0,
		name = asset_name(filename),
		pixels = slice.clone(slice.reinterpret([]Color, img.pixels.buf[:])),
	}

	append(textures, td)
}

default_context: runtime.Context

main :: proc() {
	context.logger = log.create_console_logger(opt = {.Level})
	default_context = context
	start_time := time.now()
	textures: [dynamic]Texture_Data
	animations: [dynamic]Animation

	dir_path_to_file_infos :: proc(path: string) -> []os.File_Info {
		d, derr := os.open(path, os.O_RDONLY)
		if derr != nil {
			log.panicf("No %s folder found", path)
		}
		defer os.close(d)

		{
			file_info, ferr := os.fstat(d)
			defer os.file_info_delete(file_info)

			if ferr != nil {
				log.panic("stat failed")
			}
			if !file_info.is_dir {
				log.panic("not a directory")
			}
		}

		file_infos, _ := os.read_dir(d, -1)
		return file_infos
	}

	file_infos := dir_path_to_file_infos(TEXTURES_DIR)

	slice.sort_by(file_infos, proc(i, j: os.File_Info) -> bool {
		return time.diff(i.creation_time, j.creation_time) > 0
	})

	tilesets: [dynamic]Tileset

	for fi in file_infos {
		is_ase := strings.has_suffix(fi.name, ".ase") || strings.has_suffix(fi.name, ".aseprite")
		is_png := strings.has_suffix(fi.name, ".png")
		if is_ase || is_png {
			path := fmt.tprintf("%s/%s", TEXTURES_DIR, fi.name)
			if strings.has_prefix(fi.name, "tileset") {
				t: Tileset
				t_ok: bool

				if is_ase {
					t, t_ok = load_tileset(path)
				} else if is_png {
					t, t_ok = load_png_tileset(path)
				}

				if t_ok {
					t.name = slashpath.name(fi.name)
					append(&tilesets, t)
				}
			} else if is_ase {
				load_ase_texture_data(path, &textures, &animations)	
			} else if is_png {
				load_png_texture_data(path, &textures)
			}
		}
	}

	rc: stbrp.Context
	rc_nodes: [ATLAS_SIZE]stbrp.Node
	stbrp.init_target(&rc, ATLAS_SIZE, ATLAS_SIZE, raw_data(rc_nodes[:]), ATLAS_SIZE)

	letters := utf8.string_to_runes(LETTERS_IN_FONT)
	glyphs: []Glyph

	Pack_Rect_Type :: enum {
		Texture,
		Glyph,
		Tile,
		ShapesTexture,
	}

	Pack_Rect_Item :: struct {
		type: Pack_Rect_Type,
		idx: int,
		x: int,
		y: int,
	}

	pack_rects: [dynamic]stbrp.Rect
	pack_rects_items: [dynamic]Pack_Rect_Item

	if font_data, ok := os.read_entire_file(FONT_FILENAME); ok {
		fi: stbtt.fontinfo
		if stbtt.InitFont(&fi, raw_data(font_data), 0) {
			scale_factor := stbtt.ScaleForPixelHeight(&fi, FONT_SIZE)

			ascent: c.int
			stbtt.GetFontVMetrics(&fi, &ascent, nil, nil)

			glyphs = make([]Glyph, len(letters))

			for r, r_idx in letters {
				w, h, ox, oy: c.int
				data := stbtt.GetCodepointBitmap(&fi, scale_factor, scale_factor, r, &w, &h, &ox, &oy)
				advance_x: c.int
				stbtt.GetCodepointHMetrics(&fi, r, &advance_x, nil)

				rgba_data := make([]Color, w*h)

				for i in 0..<w*h {
					a := data[i]
					rgba_data[i].r = 255
					rgba_data[i].g = 255
					rgba_data[i].b = 255
					rgba_data[i].a = a
				}

				glyphs[r_idx] = {
					image = {
						data = rgba_data,
						width = int(w),
						height = int(h),
					},
					value = r,
					offset = {int(ox), int(f32(oy) + f32(ascent)*scale_factor)},
					advance_x = int(f32(advance_x)*scale_factor),
				}

				append(&pack_rects, stbrp.Rect {
					id = i32(len(pack_rects_items)),
					w = stbrp.Coord(w) + 2,
					h = stbrp.Coord(h) + 2,
				})

				append(&pack_rects_items, Pack_Rect_Item {
					type = .Glyph,
					idx = r_idx,
				})
			}
		}
	} else {
		log.warnf("No %s file found", FONT_FILENAME)
	}

	for t, idx in textures {
		append(&pack_rects, stbrp.Rect {
			id = i32(len(pack_rects_items)),
			w = stbrp.Coord(t.source_size.x) + 1,
			h = stbrp.Coord(t.source_size.y) + 1,
		})

		append(&pack_rects_items, Pack_Rect_Item {
			type = .Texture,
			idx = idx,
		})
	}

	for &t, idx in tilesets {
		if t.pixels_size.x != 0 && t.pixels_size.y != 0 {
			h := t.pixels_size.y / TILE_SIZE
			w := t.pixels_size.x / TILE_SIZE
			top_left := -t.offset

			t_img := Image {
				data = t.pixels,
				width = t.pixels_size.x,
				height = t.pixels_size.y,
			}
			
			for x in 0 ..<w {
				for y in 0..<h {
					tx := TILE_SIZE * x + top_left.x
					ty := TILE_SIZE * y + top_left.y

					all_blank := true
					txx_loop: for txx in tx..<tx+TILE_SIZE {
						for tyy in ty..<ty+TILE_SIZE {
							if get_image_pixel(t_img, int(txx), int(tyy)) != {} {
								all_blank = false
								break txx_loop
							}
						}
					}

					if all_blank {
						continue
					}

					pad: stbrp.Coord = TILE_ADD_PADDING ? 3 : 1

					append(&pack_rects, stbrp.Rect {
						id = i32(len(pack_rects_items)),
						w = TILE_SIZE+pad,
						h = TILE_SIZE+pad,
					})

					append(&pack_rects_items, Pack_Rect_Item {
						type = .Tile,
						idx = idx,
						x = x,
						y = y,
					})
				}
			}
		}
	}

	append(&pack_rects, stbrp.Rect {
		id = i32(len(pack_rects_items)),
		w = 11,
		h = 11,
	})

	append(&pack_rects_items, Pack_Rect_Item {
		type = .ShapesTexture,
	})

	assert(len(pack_rects) == len(pack_rects_items))

	rect_pack_res := stbrp.pack_rects(&rc, raw_data(pack_rects), i32(len(pack_rects)))

	if rect_pack_res != 1 {
		log.error("Failed to pack some rects. ATLAS_SIZE too small?")
	}

	atlas_pixels := make([]Color, ATLAS_SIZE*ATLAS_SIZE)
	atlas := Image {
		data = atlas_pixels,
		width = ATLAS_SIZE,
		height = ATLAS_SIZE,
	}
	atlas_textures: [dynamic]Atlas_Texture_Rect

	atlas_glyphs: [dynamic]Atlas_Glyph
	shapes_texture_rect: Rect

	for rp in pack_rects {
		item := pack_rects_items[rp.id]

		switch item.type {
		case .ShapesTexture:
			shapes_texture_rect = Rect {int(rp.x), int(rp.y), 10, 10}
			draw_image_rectangle(&atlas, shapes_texture_rect, {255, 255, 255, 255})
		case .Texture:
			idx := item.idx

			t := textures[idx]

			t_img := Image {
				data = t.pixels,
				width = t.pixels_size.x,
				height = t.pixels_size.y,
			}

			source := Rect {t.source_offset.x, t.source_offset.y, t.source_size.x, t.source_size.y}
			draw_image(&atlas, t_img, source, {int(rp.x), int(rp.y)})

			atlas_rect := Rect {int(rp.x), int(rp.y), source.width, source.height}
			offset_right := t.document_size.x - (int(atlas_rect.width) + t.offset.x)
			offset_bottom := t.document_size.y - (int(atlas_rect.height) + t.offset.y)

			ar := Atlas_Texture_Rect {
				rect = atlas_rect,
				size = t.document_size,
				offset_top = t.offset.y,
				offset_right = offset_right,
				offset_bottom = offset_bottom,
				offset_left = t.offset.x,
				name = t.name,
				duration = t.duration,
			}

			append(&atlas_textures, ar)	
		case .Glyph:
			idx := item.idx
			g := glyphs[idx]
			img := g.image

			source := Rect {0, 0, img.width, img.height}
			dest := Rect {int(rp.x) + 1, int(rp.y) + 1, source.width, source.height}

			draw_image(&atlas, img, source, {int(rp.x) + 1, int(rp.y) + 1})

			ag := Atlas_Glyph {
				rect = dest,
				glyph = g,
			}

			append(&atlas_glyphs, ag)
		case .Tile:
			ix, iy := item.x, item.y
			tileset := &tilesets[item.idx]

			x := TILE_SIZE * ix
			y := TILE_SIZE * iy

			top_left := -tileset.offset

			t_img := Image {
				data = tileset.pixels,
				width = tileset.pixels_size.x,
				height = tileset.pixels_size.y,
			}
			
			source := Rect {x + top_left.x, y + top_left.y, TILE_SIZE, TILE_SIZE}
			offset := TILE_ADD_PADDING == true ? 1 : 0
			dest := Rect {int(rp.x) + offset, int(rp.y) + offset, source.width, source.height}

			draw_image(&atlas, t_img, source, {int(dest.x), int(dest.y)})

			when TILE_ADD_PADDING {
				ts :: TILE_SIZE
				// Top
				{
					psource := Rect {
						source.x,
						source.y,
						ts,
						1,
					}

					draw_image(&atlas, t_img, psource, {int(dest.x), int(dest.y - 1)})
				}

				// Bottom
				{
					psource := Rect {
						source.x,
						source.y + ts -1,
						ts,
						1,
					}

					draw_image(&atlas, t_img, psource, {int(dest.x), int(dest.y + ts)})
				}

				// Left
				{
					psource := Rect {
						source.x,
						source.y,
						1,
						ts,
					}
					
					draw_image(&atlas, t_img, psource, {int(dest.x - 1), int(dest.y)})
				}

				// Right
				{
					psource := Rect {
						source.x + ts - 1,
						source.y,
						1,
						ts,
					}
					
					draw_image(&atlas, t_img, psource, {int(dest.x + ts), int(dest.y)})
				}
			}

			at := Atlas_Tile_Rect {
				rect = dest,
				coord = {ix, iy},
			}

			append(&tileset.packed_rects, at)
		}
	}

	crop_size := Vec2i {
		ATLAS_SIZE,
		ATLAS_SIZE,
	}

	if ATLAS_CROP {
		max_x, max_y: int

		for c, ci in atlas_pixels {
			x := ci % ATLAS_SIZE
			y := ci / ATLAS_SIZE

			if c != {} {
				if x > max_x {
					max_x = x
				}

				if y > max_y {
					max_y = y
				}
			}
		}

		crop_size.x = max_x + 1
		crop_size.y = max_y + 1
	}

	img_write :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
		context = default_context
		dir := slashpath.dir(ATLAS_PNG_OUTPUT_PATH)
		if dir != "" {
			os.make_directory(dir)
		}
		os.write_entire_file(ATLAS_PNG_OUTPUT_PATH, slice.bytes_from_ptr(data, int(size)))
	}

	stbim.write_png_to_func(img_write, nil, c.int(crop_size.x), c.int(crop_size.y), 4, raw_data(atlas_pixels), ATLAS_SIZE * size_of(Color))

	f, _ := os.open(ATLAS_ODIN_OUTPUT_PATH, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
	defer os.close(f)

	fmt.fprintln(f, "// This file is generated by running the atlas_builder.")
	fmt.fprintf(f, "package %s\n", PACKAGE_NAME)
	fmt.fprintln(f, "")
	fmt.fprintln(f, "/*\nNote: This file assumes the existence of a type Rect that defines a rectangle in the same package, it can defined as:\n")
	fmt.fprintln(f, "\tRect :: rl.Rectangle\n")
	fmt.fprintln(f, "or if you don't use raylib:\n")
	fmt.fprintln(f, "\tRect :: struct {")
	fmt.fprintln(f, "\t\tx, y, width, height: f32,")
	fmt.fprintln(f, "\t}\n")
	fmt.fprintln(f, "or if you want to use integers (or any other numeric type):\n")
	fmt.fprintln(f, "\tRect :: struct {")
	fmt.fprintln(f, "\t\tx, y, width, height: int,")
	fmt.fprintln(f, "\t}\n")
	fmt.fprintln(f, "Just make sure you have something along those lines the same package as this file.\n*/")
	fmt.fprintln(f, "")

	fmt.fprintf(f, "TEXTURE_ATLAS_FILENAME :: \"%s\"\n", ATLAS_PNG_OUTPUT_PATH)
	fmt.fprintf(f, "ATLAS_FONT_SIZE :: %v\n", FONT_SIZE)
	fmt.fprintf(f, "LETTERS_IN_FONT :: \"%s\"\n\n", LETTERS_IN_FONT)

	fmt.fprintln(f, "// A generated square in the atlas you can use with rl.SetShapesTexture to make")
	fmt.fprintln(f, "// raylib shapes such as rl.DrawRectangleRec() use the atlas.")
	fmt.fprintf(f, "SHAPES_TEXTURE_RECT :: Rect {{%v, %v, %v, %v}}\n\n", shapes_texture_rect.x, shapes_texture_rect.y, shapes_texture_rect.width, shapes_texture_rect.height)

	fmt.fprintln(f, "Texture_Name :: enum {")
	fmt.fprint(f, "\tNone,\n")
	for r in atlas_textures {
		fmt.fprintf(f, "\t%s,\n", r.name)
	}
	fmt.fprintln(f, "}")
	fmt.fprintln(f, "")

	fmt.fprintln(f, "Atlas_Texture :: struct {")
	fmt.fprintln(f, "\trect: Rect,")
	fmt.fprintln(f, "\t// These offsets tell you how much space there is between the rect and the edge of the original document.")
	fmt.fprintln(f, "\t// The atlas is tightly packed, so empty pixels are removed. This can be especially apparent in animations where")
	fmt.fprintln(f, "\t// frames can have different offsets due to different amount of empty pixels around the frames.")
	fmt.fprintln(f, "\t// In many cases you need to add {offset_left, offset_top} to your position. But if you are")
	fmt.fprintln(f, "\t// flipping a texture, then you might need offset_bottom or offset_right.")
	fmt.fprintln(f, "\toffset_top: f32,")
	fmt.fprintln(f, "\toffset_right: f32,")
	fmt.fprintln(f, "\toffset_bottom: f32,")
	fmt.fprintln(f, "\toffset_left: f32,")
	fmt.fprintln(f, "\tdocument_size: [2]f32,")
	fmt.fprintln(f, "\tduration: f32,")
	fmt.fprintln(f, "}")
	fmt.fprintln(f, "")

	fmt.fprintln(f, "atlas_textures: [Texture_Name]Atlas_Texture = {")
	fmt.fprintln(f, "\t.None = {},")

	for r in atlas_textures {
		fmt.fprintf(f, "\t.%s = {{ rect = {{%v, %v, %v, %v}}, offset_top = %v, offset_right = %v, offset_bottom = %v, offset_left = %v, document_size = {{%v, %v}}, duration = %f}},\n", r.name, r.rect.x, r.rect.y, r.rect.width, r.rect.height, r.offset_top, r.offset_right, r.offset_bottom, r.offset_left, r.size.x, r.size.y, r.duration)
	}

	fmt.fprintln(f, "}\n")

	fmt.fprintln(f, "Animation_Name :: enum {")
	fmt.fprint(f, "\tNone,\n")
	for r in animations {
		fmt.fprintf(f, "\t%s,\n", r.name)
	}
	fmt.fprintln(f, "}")
	fmt.fprintln(f, "")

	fmt.fprintln(f, "Tag_Loop_Dir :: enum {")
	fmt.fprintln(f, "\tForward,")
	fmt.fprintln(f, "\tReverse,")
	fmt.fprintln(f, "\tPing_Pong,")
	fmt.fprintln(f, "\tPing_Pong_Reverse,")
	fmt.fprintln(f, "}")
	fmt.fprintln(f, "")

	fmt.fprintln(f, "// Any aseprite file with frames will create new animations. Also, any tags")
	fmt.fprintln(f, "// within the aseprite file will make that that into a separate animation.")
	fmt.fprintln(f, "Atlas_Animation :: struct {")
	fmt.fprintln(f, "\tfirst_frame: Texture_Name,")
	fmt.fprintln(f, "\tlast_frame: Texture_Name,")
	fmt.fprintln(f, "\tdocument_size: [2]f32,")
	fmt.fprintln(f, "\tloop_direction: Tag_Loop_Dir,")
	fmt.fprintln(f, "\trepeat: u16,")
	fmt.fprintln(f, "}")
	fmt.fprintln(f, "")

	fmt.fprintln(f, "atlas_animations := [Animation_Name]Atlas_Animation {")
	fmt.fprint(f, "\t.None = {},\n")

	for a in animations {
		fmt.fprintf(f, "\t.%v = {{ first_frame = .%v, last_frame = .%v, loop_direction = .%v, repeat = %v, document_size = {{%v, %v}} }},\n",
			a.name, a.first_texture, a.last_texture, a.loop_direction, a.repeat, a.document_size.x, a.document_size.y)
	}

	fmt.fprintln(f, "}\n")

	for &t in tilesets {
		w := t.pixels_size.x / TILE_SIZE
		h := t.pixels_size.y / TILE_SIZE

		fmt.fprintln(f, "// The rect inside the atlas where each tile has ended up.")
		fmt.fprintfln(f, "// Index using %v[x][y].", t.name)
		fmt.fprintfln(f, "%v := [%v][%v]Rect {{", t.name, w, h)

		slice.sort_by(t.packed_rects[:], proc(i, j: Atlas_Tile_Rect) -> bool {
			if i.coord.x == j.coord.x {
				return i.coord.y < j.coord.y
			}

			return i.coord.x < j.coord.x
		})

		prev_column := 0
		for p, idx in t.packed_rects {
			if idx == 0 {
				fmt.fprint(f, "\t0 = {\n")
			}

			if p.coord.x != prev_column {
				fmt.fprint(f, "\t},\n")
				fmt.fprintf(f, "\t%v = {{\n", p.coord.x)
			}

			prev_column = p.coord.x

			fmt.fprintf(f, "\t\t %v = {{%v, %v, %v, %v}},\n",
				p.coord.y, p.rect.x, p.rect.y, p.rect.width, p.rect.height)

			if idx == len(t.packed_rects) - 1 {
				fmt.fprint(f, "\t},\n")
			}
		}

		fmt.fprintln(f, "}\n")
	}


	fmt.fprintln(f, "Atlas_Glyph :: struct {")
	fmt.fprintln(f, "\trect: Rect,")
	fmt.fprintln(f, "\tvalue: rune,")
	fmt.fprintln(f, "\toffset_x: int,")
	fmt.fprintln(f, "\toffset_y: int,")
	fmt.fprintln(f, "\tadvance_x: int,")
	fmt.fprintln(f, "}")
	fmt.fprintln(f, "")

	fmt.fprintln(f, "atlas_glyphs: []Atlas_Glyph = {")

	for ag in atlas_glyphs {
		fmt.fprintf(f, "\t{{ rect = {{%v, %v, %v, %v}}, value = %q, offset_x = %v, offset_y = %v, advance_x = %v}},\n",
			ag.rect.x, ag.rect.y, ag.rect.width, ag.rect.height, ag.glyph.value, ag.glyph.offset.x, ag.glyph.offset.y, ag.glyph.advance_x)
	}

	fmt.fprintln(f, "}")

	run_time_ms := time.duration_milliseconds(time.diff(start_time, time.now()))
	log.infof(ATLAS_PNG_OUTPUT_PATH + " and " + ATLAS_ODIN_OUTPUT_PATH  + " created in %.2f ms", run_time_ms)
}
