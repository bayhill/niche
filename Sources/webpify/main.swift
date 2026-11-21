import libwebp
// Phase 0 link check: encode and mux symbols must both resolve.
print("libwebp encoder \(String(WebPGetEncoderVersion(), radix: 16)), mux \(String(WebPGetMuxVersion(), radix: 16))")
