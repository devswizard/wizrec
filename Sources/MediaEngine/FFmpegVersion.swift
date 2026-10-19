import CFFmpeg

/// libavcodec version string of the linked FFmpeg, e.g. `"63.1.102"`.
public var libavcodecVersion: String {
    let v = avcodec_version()
    return "\(v >> 16).\((v >> 8) & 0xFF).\(v & 0xFF)"
}

/// True when the linked libavcodec has a `tscc2` decoder.
public var hasTSCC2Decoder: Bool { avcodec_find_decoder(AV_CODEC_ID_TSCC2) != nil }
