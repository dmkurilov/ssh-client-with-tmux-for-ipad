## ColorSchemes

Parse iTerm2 `.itermcolors` plist files into `ColorScheme` values, and
ship a curated set of built-in schemes (Solarized Dark/Light, Dracula,
Tomorrow). Pure Swift, Foundation-only.


## Design decisions

### Strict import, helpful errors

The importer rejects any `.itermcolors` file that is missing a
required color, missing RGB components, contains non-numeric values,
or has components outside `0.0 … 1.0`. Each `ColorSchemeError`
carries (a) exactly what went wrong, (b) the source path, and (c)
concrete fix guidance ("re-export from iTerm2", "edit the value to
sit within 0.0 … 1.0"). Silent fallbacks would hide broken schemes
from the user and from us.


### Color space tagged, not converted

`SchemeColor.colorSpace` preserves the source space (`sRGB`,
`calibratedRGB`, `genericRGB`, `displayP3`, or `.other(String)`).
The importer does not convert between spaces — that's a rendering
decision the UI layer makes via `UIColor` / `CGColor` APIs, with
access to the display's actual color profile. Keeping the module
platform-agnostic means it can be unit-tested on Linux without
CoreGraphics.


### Built-ins hardcoded, not embedded plists

The four built-in schemes live in `BuiltInSchemes.swift` as Swift
literals, using a small `.hex(_:)` helper that unpacks 24-bit sRGB
integers. Shipping the same values as embedded `.itermcolors`
resources would force runtime parsing for every launch and add file
I/O where none is needed. Consumers who want the iTerm2 file on
disk can export from the app.


### `name` is caller-supplied, not file-sourced

`.itermcolors` files don't carry a scheme name — iTerm2 stores the
name in its preferences dictionary, not the preset. The importer
requires the caller to provide a name, or uses the basename when
loading from a URL. This keeps name handling explicit rather than
silently assuming a convention.
