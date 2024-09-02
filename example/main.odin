// An example of how to use the atlas builder. See README.md for an overview.

package game

import "core:math/linalg"
import "core:fmt"
import "core:slice"
import rl "vendor:raylib"

// This loads atlas.png (generated by the atlas builder) at compile time and stores it in the
// executable, the type of this constant will be `[]u8`. I.e. a slice of bytes. This means that you
// don't need atlas.png next to your game after compilation. It will live in the executable. When
// the executable starts it loads a raylib texture from this data.
ATLAS_DATA :: #load("atlas.png")

PIXEL_WINDOW_HEIGHT :: 180

Vec2 :: rl.Vector2
Rect :: rl.Rectangle

Player :: struct {
	pos: Vec2,

	// atlas-based animation. See `animation.odin`.
	anim: Animation,

	flip_x: bool,
}

player: Player

// This is loaded in `main` from `ATLAS_DATA`
atlas: rl.Texture

// This is manually constructed in `main` from the font info in `atlas.odin`
font: rl.Font

// Update proc to move player right and left and update the player's animation.
update :: proc() {
	input: Vec2

	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {
		input.x -= 1
	}
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {
		input.x += 1
	}

	if input.x != 0 {
		// Only update animation if there is input.
		animation_update(&player.anim, rl.GetFrameTime())
		player.flip_x = input.x < 0
	}

	input = linalg.normalize0(input)
	player.pos += input * rl.GetFrameTime() * 100
}

COLOR_BG :: rl.Color { 41, 61, 49, 255 }
COLOR_FG :: rl.Color { 241, 167, 189, 255 }

draw_player :: proc(p: Player) {
	// Fetch the texture for the current frame of the animation.
	anim_texture := animation_atlas_texture(p.anim)

	// The texture can have a non-zero offset. The offset records how far from the left and the top
	// of the original document this texture starts. This is so the frames can be tightly packed in
	// the atlas, skipping any empty pixels above or to the left of the frame.
	offset_pos := p.pos + anim_texture.offset

	// The region inside atlas.png where this animation frame lives
	atlas_rect := anim_texture.rect

	// Where on screen to draw the player
	dest := Rect {
		offset_pos.x,
		offset_pos.y,
		atlas_rect.width,
		atlas_rect.height,
	}

	// Flip player when walking to the left
	if p.flip_x {
		atlas_rect.width = -atlas_rect.width
	}

	// I want origin of player to be at the feet.
	// Use document_size for origin instead of anim_texture.rect.width (and height), because those
	// may vary from frame to frame due to being tightly packed in atlas.
	origin := Vec2 {
		anim_texture.document_size.x/2,
		anim_texture.document_size.y - 1, // -1 because there's an outline in the player anim that takes an extra pixel
	}

	// Draw texture. Note how we are drawing using the atlas but choosing a specific region in it
	// using atlas_rect.
	rl.DrawTexturePro(atlas, atlas_rect, dest, origin, 0, rl.WHITE)
}

draw :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground(COLOR_BG)
	
	screen_width := f32(rl.GetScreenWidth())
	screen_height := f32(rl.GetScreenHeight())

	game_camera := rl.Camera2D {
		zoom = screen_height/PIXEL_WINDOW_HEIGHT,
		target = player.pos,
		offset = { screen_width/2, screen_height/2 },
	}

	// Everything that uses the same camera, shader and texture will end up in the same draw call.
	// This means that the stuff between BeginMode2D and EndMode2D that draws textures, shapes or
	// text can be a single draw call, given that they all use the atlas and they all use the same
	// shader. All my textures, fonts and the raylib shapes-drawing-texture live within the atlas,
	// so they will all be within one draw call, given that we don't change camera or shader.
	rl.BeginMode2D(game_camera)

	// Font is setup in `load_atlased_font()` using info from `atlas.odin`
	rl.DrawTextEx(font, "Draw call 1: This text + player + background graphics + tiles", {-140, 20}, 15, 0, rl.WHITE)

	// Draw a single texture from the atlas. Just draw using atlas texture and fetch the rect of
	// a texture. The name "bush" is there because there's a file in `textures` folder called `bush.ase`
	rl.DrawTextureRec(atlas, atlas_textures[.Bush].rect, {30, -18}, rl.WHITE)
	draw_player(player)

	draw_tile :: proc(t: Tile_Id, pos: Vec2, flip_x: bool) {
		rect := atlas_tiles[t]

		if flip_x {
			rect.width = -rect.width
		}

		rl.DrawTextureRec(atlas, rect, pos, rl.WHITE)
	}

	// Draw two tiles from the tileset `textures/tileset_cave.ase` that has been merged into the
	// atlas. Y0X4 is the coordinates within the tileset. T0 means tileset 0. Currently only one
	// tileset is supported. Note that the tiles have 1 pixel padding added around them in the
	// tileset to avoid bleeding when panning the camera.
	draw_tile(.T0Y0X4, {8*10,0}, false)
	draw_tile(.T0Y0X4, {-8*10,0}, true)

	// This also uses the atlas because the shapes drawing texture is within the atlas, see `main`
	// for how I set that up.
	rl.DrawRectangleV({-8*9, 0}, {8*19, 8}, COLOR_FG)
	rl.EndMode2D()

	// Here we switch to the UI camera. The stuff drawn in here will be in a separate draw call.
	ui_camera := rl.Camera2D {
		zoom = screen_height/PIXEL_WINDOW_HEIGHT,
	}

	rl.BeginMode2D(ui_camera)
	rl.DrawTextEx(font, fmt.ctprintf("Draw call 2: This UI\nplayer_pos: %v", player.pos), {5, 5}, 20, 0, rl.WHITE)
	rl.EndMode2D()

	// Total draw calls for this frame: 2

	rl.EndDrawing()
}

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(1280, 720, "Atlas builder example with animations")
	rl.SetWindowPosition(200, 200)
	rl.SetTargetFPS(500)

	player = {
		// It's called Player because there is a `player.ase` file in `textures` folder that has
		// more than one frame.
		//
		// Also, if an ase file has tags in it, then those tags will be used to create several
		// animations. `player.ase` has no tags, but if it had a tag called `walk` then there would
		// be an animation called `Player_Walk` that you could use here.
		anim = animation_create(.Player),
	}
	
	// Load atlas from ATLAS_DATA, which was stored in the executable at compile-time.
	atlas_image := rl.LoadImageFromMemory(".png", raw_data(ATLAS_DATA), i32(len(ATLAS_DATA)))
	atlas = rl.LoadTextureFromImage(atlas_image)
	rl.UnloadImage(atlas_image)

	font = load_atlased_font()

	// Set the shapes drawing texture, this makes rl.DrawRectangleRec etc use the atlas
	rl.SetShapesTexture(atlas, shapes_texture_rect)

	for !rl.WindowShouldClose() {
		update()
		draw()
	}

	rl.UnloadTexture(atlas)
	delete_atlased_font(font)
	rl.CloseWindow()
}

delete_atlased_font :: proc(font: rl.Font) {
	delete(slice.from_ptr(font.glyphs, int(font.glyphCount)))
	delete(slice.from_ptr(font.recs, int(font.glyphCount)))
}

// This uses the letters in the atlas to create a raylib font. Since this font is in the atlas
// it can be drawn in the same draw call as the other graphics in the atlas. Don't use
// rl.UnloadFont() to destroy this font, instead use `delete_atlased_font`, since we've set up the
// memory ourselves.
//
// The set of available glyphs is governed by `LETTERS_IN_FONT` in `atlas_builder.odin`
// The font used is governed by `FONT_FILENAME` in `atlas_builder.odin`
load_atlased_font :: proc() -> rl.Font {
	num_glyphs := len(atlas_glyphs)
	font_rects := make([]Rect, num_glyphs)
	glyphs := make([]rl.GlyphInfo, num_glyphs)

	for ag, idx in atlas_glyphs {
		font_rects[idx] = ag.rect
		glyphs[idx] = {
			value = ag.value,
			offsetX = i32(ag.offset_x),
			offsetY = i32(ag.offset_y),
			advanceX = i32(ag.advance_x),
		}
	} 

	return {
		baseSize = ATLAS_FONT_SIZE,
		glyphCount = i32(num_glyphs),
		glyphPadding = 0,
		texture = atlas,
		recs = raw_data(font_rects),
		glyphs = raw_data(glyphs),
	}
}