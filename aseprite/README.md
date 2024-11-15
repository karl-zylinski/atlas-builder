# Odin Aseprite
Handler for Aseprite's `.ase`/`.aseprite`, `.aseprite-extension` &amp; extended `.gpl` files writen in Odin.   

* `.\`: Main un/marshaler for `.ase`
* `.\utils`: Creates Images & Animations from Documents
* `.\raw`: un/marshals `.ase` exactly as given by the spec
* `.\gpl`: extended & normal .gpl   
* `.\extensions`: .aseprite-extension. WIP   
* `.\tests`: test files

## Examples
### aseprite
```odin
package main

import "core:fmt"
import ase "odin-aseprite"

main :: proc() {
    data := #load("geralt.aseprite")

    doc: ase.Document
    defer ase.destroy_doc(&doc)

    umerr := ase.unmarshal(data[:], &doc)
    if umerr != nil {
        fmt.println(umerr)
        return
    }

    buf: [dynamic]byte
    defer delete(buf)

    written, merr := ase.marshal(&buf, &doc)
    if merr != nil {
        fmt.println(merr)
        return
    }
}
```

### utils
```odin
package main

import "core:fmt"
import ase "odin-aseprite"
import "odin-aseprite/utils"

main :: proc() {
    data := #load("geralt.aseprite")

    doc: ase.Document
    defer ase.destroy_doc(&doc)

    umerr := ase.unmarshal(data[:], &doc)
    if umerr != nil {
        fmt.println(umerr)
        return
    }

    imgs, imgs_err := utils.get_all_images(&doc)
    defer utils.destroy(imgs)

    if imgs_err != nil {
        fmt.println(imgs_err)
        return
    }
}
```

### gpl
```odin
package main

import "core:fmt"
import "odin-aseprite/gpl"

main :: proc() {
    data := #load("geralt.gpl")

    palette, err := gpl.parse(data[:])
    if err != nil {
        fmt.println(err)
        return
    }
    defer destroy_gpl(&palette)

    buf, err2 := gpl.to_bytes(palette)
    if err2 != nil {
        fmt.println(err2)
        return
    } 
    defer delete(buf)
}
```


## Warnings
ICC Colour Profiles aren't supported. The raw data will be saved to doc.   

## Errors
Any errors please make an issue or DM them to me, `blob1807`, on the [Odin Discord](https://discord.com/invite/sVBPHEv).  
If you DM me please include the offending file/s.   
   
If you want to test your own files for errors. Add them to a new folder in `./tests` and run `odin test .` in the `./tests` directory.
