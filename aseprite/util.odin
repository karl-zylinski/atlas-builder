package aseprite_file_handler

import ir "base:intrinsics"
import "core:log"
import "core:reflect"
import "core:encoding/endian"

@(require) import "core:strconv"
_ :: reflect

get_chunk_type :: proc(c: Chunk) -> (type: WORD, err: Marshal_Error) {
    switch _ in c {
    case Old_Palette_256_Chunk:
        type = WORD(Chunk_Types.old_palette_256)
    case Old_Palette_64_Chunk:
        type = WORD(Chunk_Types.old_palette_64)
    case Layer_Chunk:
        type = WORD(Chunk_Types.layer)
    case Cel_Chunk:
        type = WORD(Chunk_Types.cel)
    case Cel_Extra_Chunk:
        type = WORD(Chunk_Types.cel_extra)
    case Color_Profile_Chunk:
        type = WORD(Chunk_Types.color_profile)
    case External_Files_Chunk:
        type = WORD(Chunk_Types.external_files)
    case Mask_Chunk:
        type = WORD(Chunk_Types.mask)
    case Path_Chunk:
        type = WORD(Chunk_Types.path)
    case Tags_Chunk:
        type = WORD(Chunk_Types.tags)
    case Palette_Chunk:
        type = WORD(Chunk_Types.palette)
    case User_Data_Chunk:
        type = WORD(Chunk_Types.user_data)
    case Slice_Chunk:
        type = WORD(Chunk_Types.slice)
    case Tileset_Chunk:
        type = WORD(Chunk_Types.tileset)
    case:
        err = .Invalid_Chunk_Type
    }
    return
}

get_cel_type :: proc(c: Cel_Type) -> (type: WORD, err: Marshal_Error) {
    switch _ in c {
        case Raw_Cel:
            type = WORD(Cel_Types.Raw)
        case Linked_Cel:
            type = WORD(Cel_Types.Linked_Cel)
        case Com_Image_Cel:
            type = WORD(Cel_Types.Compressed_Image)
        case Com_Tilemap_Cel:
            type = WORD(Cel_Types.Compressed_Tilemap)
        case:
            err = .Invalid_Cel_Type
    }
    return
}

get_property_type :: proc(v: Property_Value) -> (type: WORD, err: Marshal_Error) {
    switch t in v {
    case nil:        type = WORD(Property_Type.Null)
    case bool:       type = WORD(Property_Type.Bool)
    case i8:         type = WORD(Property_Type.I8)
    case BYTE:       type = WORD(Property_Type.U8)
    case SHORT:      type = WORD(Property_Type.I16)
    case WORD:       type = WORD(Property_Type.U16)
    case LONG:       type = WORD(Property_Type.I32)
    case DWORD:      type = WORD(Property_Type.U32)
    case LONG64:     type = WORD(Property_Type.I64)
    case QWORD:      type = WORD(Property_Type.U64)
    case FIXED:      type = WORD(Property_Type.Fixed)
    case FLOAT:      type = WORD(Property_Type.F32)
    case DOUBLE:     type = WORD(Property_Type.F64)
    case STRING:     type = WORD(Property_Type.String)
    case POINT:      type = WORD(Property_Type.Point)
    case SIZE:       type = WORD(Property_Type.Size)
    case RECT:       type = WORD(Property_Type.Rect)
    case UUID:       type = WORD(Property_Type.UUID)
    case UD_Vec:     type = WORD(Property_Type.Vector)
    case Properties: type = WORD(Property_Type.Properties)
    case:             err = Marshal_Errors.Invalid_Property_Type
    }
    return
}

tiles_to_u8 :: proc(tiles: []TILE, b: []u8) -> (pos: int, err: Write_Error) {
    next: int
    for t in tiles {
        switch v in t {
        case BYTE:
            pos = next
            next += size_of(BYTE)
            b[pos] = v
        case WORD:
            pos = next
            next += size_of(WORD)
            if !endian.put_u16(b[pos:next], .Little, v) {
                return 0, .Unable_To_Encode_Data
            }
        case DWORD:
            pos = next
            next += size_of(DWORD)
            if !endian.put_u32(b[pos:next], .Little, v) {
                return 0, .Unable_To_Encode_Data
            }
        }
    }
    pos = next
    return
}


@(private)
fast_log_str :: proc(lvl: log.Level, str: string, loc := #caller_location) {
    logger := context.logger
    if logger.procedure == nil { return }
    if lvl < logger.lowest_level { return }
    logger.procedure(logger.data, lvl, str, logger.options, loc)
}

@(private)
fast_log_str_enum :: proc(lvl: log.Level, str: string, val: $T, sep := " ", loc := #caller_location) where ir.type_is_enum(T) {
    logger := context.logger
    if logger.procedure == nil { return }
    if lvl < logger.lowest_level { return }

    s := reflect.enum_string(val)
    buf := make([]u8, len(str) + len(sep) + len(s))
    defer delete(buf)

    n := copy(buf[:], str)
    n += copy(buf[n:], sep)
    copy(buf[n:], s)

    logger.procedure(logger.data, lvl, string(buf), logger.options, loc)
}

@(private)
fast_log_str_num :: proc(lvl: log.Level, str: string, val: $T, sep := " ", loc := #caller_location) where ir.type_is_numeric(T) {
    logger := context.logger
    if logger.procedure == nil { return }
    if lvl < logger.lowest_level { return }

    nb: [32]u8
    s := strconv.append_int(nb[:], i64(val), 10)
    buf := make([]u8, len(str) + len(sep) + len(s))
    defer delete(buf)

    n := copy(buf[:], str)
    n += copy(buf[n:], sep)
    copy(buf[n:], s)

    logger.procedure(logger.data, lvl, string(buf), logger.options, loc)
}

@(private)
fast_log :: proc {fast_log_str, fast_log_str_enum, fast_log_str_num}
