#!/usr/bin/env bash

# First run the stuff in the parent directory, i.e. the atlas builder.
# It will make atlas.png and atlas.odin based on the stuff in `textures` and `font.ttf`

# If the atlas builder succeeds then we run the stuff in the current directory,
# which is the example that shows how to use atlas and do atlased animations.

# Note: We can't do `odin run ..` on linux due to a bug in the compiler. It works
# on windows.

odin run ../atlas_builder.odin -file -vet -strict-style && odin run . -vet -strict-style -out:example.bin
