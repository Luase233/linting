import Foundation
import ImageIO

enum PhotoProcessing {
    static func jpegForAnalysis(from data: Data) -> Data? {
        guard !data.isEmpty, data.count <= 40_000_000,
              let source = CGImageSourceCreateWithData(data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: CloudVisionPolicy.maximumImageDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        // Encode only raster pixels. Never copy EXIF/GPS, capture time, filename or album data.
        for quality in [0.74, 0.55, 0.35] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= CloudVisionPolicy.maximumImageBytes {
                return output as Data
            }
        }
        return nil
    }
}
