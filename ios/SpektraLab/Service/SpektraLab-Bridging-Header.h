//  SpektraLab-Bridging-Header.h — the engine's C ABI, to Swift.
//
//  One import, and it is the whole engine surface. The header is a hand-
//  written C ABI rather than Swift's C++ interop (RFC-014 §2.1): it is
//  stable across toolchains, drivable from Swift, C++ and ctypes alike, and
//  it forces the boundary to stay narrow — a `std::vector<Node>` cannot
//  cross it by accident.
//
//  The engine's C++ is compiled into this target as sources (see
//  `ios/Tools/gen-project.py`), so there is no library to link and no
//  modulemap to write.

#import "spektrafilm/spk_engine.h"
#import "RAWDecodeSupport.h"
#import "LibRawDecodeSupport.h"
